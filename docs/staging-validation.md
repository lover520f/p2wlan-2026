# Actions 服务端 staging 验证

`.github/workflows/build-server.yml` 在 `server-v*` 标签或手动触发时构建 Linux amd64/arm64 服务端。手动触发并把 `deploy_staging` 设为 true 才会上传测试包。

staging 环境需要配置以下 GitHub Environment 值：

- `STAGING_HOST=47.109.40.237`
- `STAGING_USER`：隔离部署账号，不默认假设 root
- `STAGING_PORT`：通常为 22
- `STAGING_SSH_PRIVATE_KEY`：CI 专用私钥 secret，不能使用本地路径或把 `~/.ssh/ali.pem` 提交到仓库
- `STAGING_KNOWN_HOSTS`：人工核验后的主机指纹

部署 job 只上传已构建的归档和校验文件，在远端再次执行 `sha256sum -c`。runner 不在云机编译源码，也不会关闭 StrictHostKeyChecking。每个 run 使用独立的临时目录，失败后清理；正式服务和测试服务必须使用独立端口、数据目录及 systemd unit。

集成门禁应覆盖双客户端登录、资料读取、创建/加入房间、设备注册、持久化信令和 ACK、Direct、强制 Relay、票据过期/撤销、服务器重启、WebSocket 断开恢复、升级和回滚。只检查端口或 `/health` 不算业务通过。

证据需要记录 Actions run、源码 SHA、包校验和、云机架构、control/relay 实际版本、测试结果和恢复结果。账号密码、JWT、邀请 token、Relay 私钥、SSH 私钥和完整环境文件不得进入日志或 artifact。
