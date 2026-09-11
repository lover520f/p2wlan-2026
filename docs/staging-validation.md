# Actions 服务端 staging 验证

`.github/workflows/build-server.yml` 在 `server-v*` 标签或手动触发时构建 Linux amd64/arm64 服务端。手动触发并把 `deploy_staging` 设为 true 才会连接 staging；`deployment_mode` 可选：

- `smoke-upload`：上传包到临时目录，用高端口启动临时 control/relay，验证 checksum、版本和 `/health`，不修改正式安装。
- `install-upload`：选择远端架构的包，执行安装或更新、systemd 启动、`verify` 和 `check`。
- `remote-fetch`：不上传包，让远端已有 `p2wlan-server` manager 通过 Release URL 拉取指定 `server_version`，然后更新并检查。

staging 环境需要配置以下 GitHub Environment 值：

- `STAGING_HOST=47.109.40.237`
- `STAGING_USER`：隔离部署账号，不默认假设 root
- `STAGING_PORT`：通常为 22
- `STAGING_SSH_PRIVATE_KEY`：CI 专用私钥 secret，不能使用本地路径或把 `~/.ssh/ali.pem` 提交到仓库
- `STAGING_KNOWN_HOSTS`：人工核验后的主机指纹

`install-upload` 和 `remote-fetch` 还要求 `STAGING_USER` 能够无交互执行受限的 `sudo`。Actions runner 不能输入服务器密码；如果服务器只有密码登录或 sudo 需要交互密码，请使用本地 `scripts/deploy-server.sh`，它会让 OpenSSH 和 sudo 在终端提示用户输入，不会把密码写进参数。

部署 job 只上传已构建的归档和校验文件，在远端再次执行 `sha256sum -c`；服务端拉取模式由远端 manager 自行下载并校验。runner 不在云机编译源码，也不会关闭 StrictHostKeyChecking。每个 run 使用独立的临时目录，失败后清理；正式服务和测试服务必须使用独立端口、数据目录及 systemd unit。

集成门禁应覆盖双客户端登录、资料读取、创建/加入房间、设备注册、持久化信令和 ACK、Direct、强制 Relay、票据过期/撤销、服务器重启、WebSocket 断开恢复、升级和回滚。只检查端口或 `/health` 不算业务通过。

证据需要记录 Actions run、源码 SHA、包校验和、云机架构、control/relay 实际版本、测试结果和恢复结果。账号密码、JWT、邀请 token、Relay 私钥、SSH 私钥和完整环境文件不得进入日志或 artifact。
