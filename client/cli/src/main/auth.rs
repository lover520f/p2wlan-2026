async fn authenticate(path: &Path, args: AuthArgs, register: bool) -> Result<(), String> {
    reject_sudo_config_write()?;
    let email = args.username.trim().to_lowercase();
    if email.is_empty() || !email.contains('@') {
        return Err("请输入有效邮箱地址".to_string());
    }
    let password = match args.password {
        Some(password) => password,
        None => rpassword::prompt_password("密码: ")
            .map_err(|error| format!("无法从终端读取密码：{error}"))?,
    };
    if password.len() < 6 {
        return Err("密码至少需要 6 个字符".to_string());
    }

    let existing = if path.exists() {
        Some(load_config(path)?)
    } else {
        None
    };
    let server = args
        .server
        .or_else(|| {
            existing
                .as_ref()
                .map(|config| config.control.server_url.clone())
        })
        .unwrap_or_else(|| DEFAULT_CONTROL_SERVER.to_string());
    let server = normalize_control_server(&server)?;
    let endpoint = format!(
        "{server}/api/v1/{}",
        if register { "register" } else { "login" }
    );
    // The control server login never goes through a proxy: the request is a
    // one-shot credential exchange with the control plane itself, and a
    // system-level HTTP proxy would otherwise intercept loopback/LAN control
    // servers (some proxy clients even answer 502 for loopback).  HTTP(S)_PROXY
    // environment variables are deliberately NOT consulted here either.
    let response = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .no_proxy()
        .build()
        .map_err(|error| format!("无法初始化网络请求：{error}"))?
        .post(endpoint)
        .header(reqwest::header::ACCEPT, "application/json")
        .json(&serde_json::json!({ "email": email, "password": password }))
        .send()
        .await
        .map_err(|error| {
            if error.is_timeout() {
                "连接控制服务器超时".to_string()
            } else {
                format!("无法连接控制服务器：{error}")
            }
        })?;
    let status = response.status();
    let body_text = response
        .text()
        .await
        .map_err(|error| format!("无法读取控制服务器响应：{error}"))?;
    let body: AuthResponse = serde_json::from_str(&body_text)
        .map_err(|_| format!("控制服务器返回了无效响应（HTTP {status}）"))?;
    if !status.is_success() || body.success != Some(true) {
        return Err(auth_error(
            body.error.as_deref().unwrap_or(&body_text),
            status.as_u16(),
        ));
    }
    let token = body
        .token
        .filter(|token| !token.trim().is_empty())
        .ok_or_else(|| "控制服务器没有返回有效 token".to_string())?;

    let mut config = match existing {
        Some(config) => config,
        None => Config::generate_default(&server, DEFAULT_NETWORK)
            .map_err(|error| format!("无法生成配置：{error}"))?,
    };
    config.control.server_url = server.clone();
    config.control.auth_token = token.clone();
    config.control.device_credential.clear();
    config.control.credential_issued = false;
    config.diagnostics.enabled = true;
    config.diagnostics.bind = DEFAULT_DIAGNOSTICS_BIND.to_string();
    save_config(&config, path)?;
    save_cli_session_token(path, &token)?;

    println!(
        "{}成功：{}\n控制服务器：{}\n配置文件：{}",
        if register { "注册" } else { "登录" },
        email,
        server,
        path.display()
    );
    Ok(())
}

async fn logout(path: &Path) -> Result<(), String> {
    reject_sudo_config_write()?;
    let mut config = load_config(path)?;
    if let Err(error) = revoke_current_device_credential(&config).await {
        eprintln!("警告：无法撤销远端设备凭证：{error}");
    }
    config.control.auth_token.clear();
    config.control.device_credential.clear();
    config.control.credential_issued = false;
    save_config(&config, path)?;
    clear_cli_session_token(path)?;
    println!("已退出登录，设备身份密钥和网络设置已保留。");
    Ok(())
}

/// Keep the account JWT available to user-facing control-plane commands even
/// after the daemon exchanges it for a durable device credential and removes
/// the JWT from its runtime config. The sidecar is never passed to the daemon
/// and is always owner-readable only on Unix.
fn cli_session_path(config_path: &Path) -> PathBuf {
    config_path.with_extension("session")
}

fn save_cli_session_token(config_path: &Path, token: &str) -> Result<(), String> {
    let token = token.trim();
    if token.is_empty() {
        return Err("控制服务器返回了空的 CLI 会话 token".to_string());
    }
    let path = cli_session_path(config_path);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("无法创建 CLI 会话目录 {}：{error}", parent.display()))?;
    }
    let temp = path.with_extension("session.tmp");
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&temp)
        .map_err(|error| format!("无法创建 CLI 会话文件 {}：{error}", temp.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = file
            .metadata()
            .map_err(|error| format!("无法读取 CLI 会话文件权限：{error}"))?
            .permissions();
        permissions.set_mode(0o600);
        file.set_permissions(permissions)
            .map_err(|error| format!("无法设置 CLI 会话文件权限：{error}"))?;
    }
    file.write_all(token.as_bytes())
        .and_then(|_| file.write_all(b"\n"))
        .and_then(|_| file.sync_all())
        .map_err(|error| format!("无法写入 CLI 会话文件：{error}"))?;
    drop(file);
    fs::rename(&temp, &path)
        .map_err(|error| format!("无法保存 CLI 会话文件 {}：{error}", path.display()))
}

fn read_cli_session_token(config_path: &Path) -> Result<Option<String>, String> {
    let path = cli_session_path(config_path);
    #[cfg(unix)]
    if let Ok(metadata) = fs::metadata(&path) {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o077 != 0 {
            return Err(format!(
                "CLI 会话文件 {} 权限过宽，请设置为 0600 或重新登录",
                path.display()
            ));
        }
    }
    match fs::read_to_string(&path) {
        Ok(value) => {
            let token = value.trim();
            if token.is_empty() {
                Err(format!("CLI 会话文件 {} 为空，请重新登录", path.display()))
            } else {
                Ok(Some(token.to_string()))
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("无法读取 CLI 会话文件 {}：{error}", path.display())),
    }
}

fn hydrate_cli_session_token(config_path: &Path, config: &mut Config) -> Result<(), String> {
    if config.control.auth_token.trim().is_empty() {
        if let Some(token) = read_cli_session_token(config_path)? {
            config.control.auth_token = token;
        }
    }
    Ok(())
}

fn cli_session_available(config_path: &Path, config: &Config) -> Result<bool, String> {
    if !config.control.auth_token.trim().is_empty() {
        return Ok(true);
    }
    Ok(read_cli_session_token(config_path)?.is_some())
}

fn clear_cli_session_token(config_path: &Path) -> Result<(), String> {
    let path = cli_session_path(config_path);
    match fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("无法删除 CLI 会话文件 {}：{error}", path.display())),
    }
}

async fn revoke_current_device_credential(config: &Config) -> Result<(), String> {
    let credential = config.control.device_credential.trim();
    if credential.is_empty() {
        return Ok(());
    }
    let server = normalize_control_server(&config.control.server_url)?;
    let response = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .no_proxy()
        .build()
        .map_err(|error| format!("无法初始化网络请求：{error}"))?
        .delete(format!("{server}/api/v1/devices/credential"))
        .bearer_auth(credential)
        .header(reqwest::header::ACCEPT, "application/json")
        .send()
        .await
        .map_err(|error| {
            if error.is_timeout() {
                "连接控制服务器超时".to_string()
            } else {
                format!("无法连接控制服务器：{error}")
            }
        })?;
    if response.status().is_success() || response.status() == reqwest::StatusCode::UNAUTHORIZED {
        return Ok(());
    }
    let status = response.status();
    let body = response.text().await.unwrap_or_default();
    Err(format!("HTTP {status}: {body}"))
}
