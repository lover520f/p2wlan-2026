# P2WLAN 服务端部署

服务端分为 control 和 relay 两个进程。control 提供账号、设备注册、持久化信令和 Relay 票据；relay 只转发已认证的密文。客户端不会自动使用任何项目服务器，安装后必须手动填写自己的 control URL。

## 安装

从服务端 Release 下载对应架构的 `p2wlan-server-linux-amd64.tar.gz` 或 `p2wlan-server-linux-arm64.tar.gz`，同时下载同名 `.sha256` 文件。把两个文件和包内的 `install-server.sh`、`p2wlan-server` 放在同一目录后运行：

```bash
sha256sum -c p2wlan-server-linux-amd64.tar.gz.sha256
sudo ./install-server.sh --archive p2wlan-server-linux-amd64.tar.gz --role all
sudo p2wlan-server status
```

在线安装必须指定完整的 `server-vX.Y.Z` 版本：

```bash
curl -fLO https://github.com/yhan-sun/p2wlan/releases/download/server-vX.Y.Z/p2wlan-server-linux-amd64.tar.gz
curl -fLO https://github.com/yhan-sun/p2wlan/releases/download/server-vX.Y.Z/p2wlan-server-linux-amd64.tar.gz.sha256
sudo ./install-server.sh --version server-vX.Y.Z --role all
```

默认目录是：程序 `/opt/p2wlan-server`，配置 `/etc/p2wlan`，数据 `/var/lib/p2wlan`，管理命令 `/usr/local/bin/p2wlan-server`。可以用 `P2WLAN_SERVER_ROOT`、`P2WLAN_SERVER_CONFIG`、`P2WLAN_SERVER_DATA` 指向隔离测试目录。

## 初始化配置

`p2wlan-server init` 创建专用 `p2wlan` 用户、配置文件和数据目录。首次生成的 control 配置包含随机 `JWT_SECRET`；该文件权限为 0600，不能提交到 Git 或写入 CI 日志。

```bash
sudo p2wlan-server init --role all
sudoedit /etc/p2wlan/control.env
sudoedit /etc/p2wlan/relay.env
```

生产环境必须配置 HTTPS 反向代理、Relay TLS、DNS/证书、`RELAY_CATALOG_JSON`、Relay 票据签发密钥和对应的 relay 验签 keyring。`RELAY_ALLOW_INSECURE_PLAINTEXT=true` 只允许隔离开发测试，不能用于公网。

如果使用 systemd，管理器会安装 `p2wlan-control.service` 和 `p2wlan-relay.service`：

```bash
sudo systemctl enable --now p2wlan-control.service p2wlan-relay.service
sudo p2wlan-server status
sudo p2wlan-server logs control
```

服务端版本可独立检查：

```bash
/opt/p2wlan-server/current/p2wlan-control --version
/opt/p2wlan-server/current/p2wlan-relay --version
curl -fsS http://127.0.0.1:18080/health
```

服务端监听端口和公网暴露策略由 `control.env`、`relay.env` 及反向代理配置决定。防火墙只开放实际使用的 TCP/UDP 端口，管理端口不要直接暴露给公网。
