# P2WLAN 服务端独立升级与回滚

服务端使用 `server-vX.Y.Z` 标签和独立 Release。服务端升级不会自动构建或发布客户端；客户端 `vX.Y.Z` 和服务端 `server-vX.Y.Z` 需要按兼容矩阵分别选择。

升级前先备份数据库和配置：

```bash
sudo p2wlan-server backup
sudo p2wlan-server status
```

下载目标架构的包及校验文件后，校验通过再切换：

```bash
sudo p2wlan-server update --archive p2wlan-server-linux-amd64.tar.gz
sudo p2wlan-server status
```

或从固定标签下载并校验：

```bash
sudo p2wlan-server update --version server-vX.Y.Z
```

更新器把二进制放进版本目录，再更新 `current` 链接；配置、SQLite 数据和密钥不会被覆盖。systemd 可用时会重启选择的服务，非 systemd 主机需要自行按同一顺序停止、切换并健康检查。

升级失败时先保留日志和失败版本目录，再回滚到上一套已验证版本：

```bash
sudo p2wlan-server rollback
sudo p2wlan-server status
```

数据库使用 WAL 时必须进行停服务一致性备份；不能只复制正在运行的主数据库文件。若新版本数据库迁移不可逆，升级前必须保留完整备份，并拒绝把旧二进制直接配新数据库当作安全回滚。

升级验收至少包括 `/health`、`--version`、登录、设备注册、信令 ACK、直连/Relay、重启恢复和旧客户端兼容性。构建成功、Release 成功和实际服务端升级成功是三个独立结论。
