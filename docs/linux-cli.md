# Linux CLI 与 systemd 部署

Linux CLI 包含 `p2wlan` 控制命令和 `p2wlan-daemon` 数据面 daemon。CLI 负责登录、配置、房间控制面操作、诊断和多房间实例生命周期；daemon 负责 TUN、路由、NAT traversal、Direct/Relay 数据路径和加密会话。

## 安装

从 Release 下载对应架构的 `p2wlan-linux-x64-cli.tar.gz` 或 `p2wlan-linux-arm64-cli.tar.gz`，然后执行：

```bash
tar -xzf p2wlan-linux-x64-cli.tar.gz
cd p2wlan-linux-x64-cli
sudo ./install.sh
```

也可以使用在线安装脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/yhan-sun/p2wlan/main/scripts/install-linux-cli.sh -o /tmp/p2wlan-install.sh
sudo sh /tmp/p2wlan-install.sh
```

登录和配置不要加 `sudo`。普通前台 CLI 会在 `p2wlan up` 启动 daemon 时只为创建 TUN 和路由请求管理员权限。

## 基本生命周期

```bash
p2wlan login -u you@example.com
p2wlan config show
p2wlan up
p2wlan status
p2wlan logs -f
p2wlan down
```

配置文件默认位于 `$XDG_CONFIG_HOME/p2wlan/p2wlan-config.json`，状态和日志默认位于 `$XDG_STATE_HOME/p2wlan`。可用全局 `--config PATH`、`P2WLAN_CONFIG` 和 `P2WLAN_STATE_DIR` 覆盖路径。

登录后的 CLI 用户会话保存在配置文件旁的 `.session` 文件中，权限为 `0600`。daemon 获取 device credential 后可以清掉配置内的用户 JWT，但 `room` 和 `support-bundle --upload` 仍能继续使用 CLI 会话。

## Direct / Relay 和控制面代理策略

这些设置会写入 daemon 配置，重启后生效：

```bash
# 控制面 HTTP：direct（默认）或显式使用 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY
p2wlan config set proxy-mode direct
p2wlan config set proxy-mode environment

# 兼容的 Direct/Relay 总策略
p2wlan config set relay-policy auto
p2wlan config set relay-policy direct
p2wlan config set relay-policy prefer-relay
p2wlan config set relay-policy relay
p2wlan config set prefer-direct on
p2wlan config set prefer-direct off

# 完整数据路径策略
p2wlan config set path-policy auto
p2wlan config set path-policy score
p2wlan config set path-policy direct-sticky
p2wlan config set path-policy relay-only

# Relay 候选与选择超时
p2wlan config set relay-regions cn-east,cn-north
p2wlan config set relay-selection-timeout 2000ms
p2wlan config set relay-startup-timeout 3000ms
```

`auto` 保留启动阶段的 Relay 安全门控，`score` 按已确认路径质量选择，`direct-sticky` 在 Direct 加密验证成功后保持 Direct，`relay-only` 禁止 Direct 数据路径提升。`relay-policy relay` 是 `relay-only` 的兼容别名；`proxy-mode` 只影响控制面 HTTP，不会把 UDP peer 端点交给代理。

查看当前有效值：

```bash
p2wlan config show
```

## 房间管理

房间控制面命令使用当前登录账号的控制服务器：

```bash
p2wlan room list
p2wlan room create --name minecraft --password 'change-me'
p2wlan room join --code 12345678
p2wlan room show 12345678
p2wlan room invite 12345678 --ttl-hours 24 --max-uses 10
p2wlan room invites 12345678
p2wlan room rename 12345678 --name survival
p2wlan room password 12345678
p2wlan room member-remove 12345678 --user usr-...
p2wlan room ban 12345678 --user usr-...
p2wlan room unban 12345678 --user usr-...
p2wlan room device-ip 12345678 --device dev-... --ip 10.21.7.42
p2wlan room device-remove 12345678 --device dev-...
p2wlan room leave 12345678
```

密码选项可以省略，CLI 会通过无回显提示读取。邀请 token 不会写入本地房间配置；创建邀请后 CLI 会同时打印 token 和 `p2wlan://join` 邀请链接。

### 连接多个房间

加入房间后，使用 `room connect` 启动一个独立 daemon 实例：

```bash
p2wlan room connect 12345678
p2wlan room disconnect 12345678
```

每个房间使用独立的配置和运行目录：

- 配置：`~/.config/p2wlan/rooms/<profile-id>/p2wlan-config.json`
- 日志、PID 和诊断 token：`~/.local/state/p2wlan/rooms/<profile-id>/`
- TUN：`p2r<profile-id 前 12 位>`
- 诊断端口：`40000 + profile-id 前 8 位十六进制对 20000 取模`
- UDP：`0.0.0.0:0`，避免多个房间争用固定端口

`room leave` 会先停止对应本地 daemon；房间 owner 执行该命令会删除房间，普通成员则退出房间。房间 profile 使用独立节点身份，不会把个人网络的 device credential 迁移到房间。

房间密码遵循服务端限制：8–72 个字节；邀请有效期为 1–168 小时，最多使用 1000 次。

## 路由校验和修复

daemon 已运行时，可以读取实际 Linux 路由表并在不重启 TUN 或 peer 会话的情况下修复 overlay route：

```bash
p2wlan route verify
p2wlan route verify --json
p2wlan route repair
p2wlan route repair --json
```

`verify` 遇到 `missing`、`conflict` 或 `unknown` 会以失败状态退出；`repair` 只处理 daemon 自己配置的 overlay CIDR，不会删除无关路由。

## 支持包

`support-bundle` 收集当前 daemon 日志尾部、状态摘要以及最多 8 个本地房间 profile，生成服务端可读取的 gzip JSON。凭据、Bearer token、密码、私钥和邀请 token 会在写盘前做脱敏；输出文件权限为 `0600`。

```bash
p2wlan support-bundle
p2wlan support-bundle --output /tmp/p2wlan-support.json.gz
p2wlan support-bundle --upload
p2wlan support-bundle --include-rooms=false --json
```

`--upload` 会把同一份压缩包上传到 `/api/v1/support/logs`，需要当前登录凭证。上传前仍建议确认输出文件不包含不应外发的业务信息。

## systemd

仓库提供 [deploy/systemd/p2wlan-daemon.service](../deploy/systemd/p2wlan-daemon.service)。它以专用的 `p2wlan` 用户运行，只授予 TUN/路由所需的 `CAP_NET_ADMIN` 和 `CAP_NET_RAW`。

```bash
sudo useradd --system --home-dir /var/lib/p2wlan --create-home --shell /usr/sbin/nologin p2wlan
sudo install -d -o p2wlan -g p2wlan -m 0750 /etc/p2wlan /var/log/p2wlan
sudo install -m 0644 deploy/systemd/p2wlan-daemon.service /etc/systemd/system/p2wlan-daemon.service
sudo -u p2wlan /usr/local/bin/p2wlan-daemon --init \
  --config /etc/p2wlan/p2wlan-config.json \
  --control https://control.example.com \
  --network default
# This writes the initial user JWT into the 0600 config. The daemon exchanges
# it for a durable device credential on first start and then removes the JWT.
sudo -u p2wlan /usr/local/bin/p2wlan \
  --config /etc/p2wlan/p2wlan-config.json login -u you@example.com
sudo systemctl daemon-reload
sudo systemctl enable --now p2wlan-daemon.service
sudo systemctl status p2wlan-daemon.service
```

请把服务文件中的 `/usr/local/bin`、配置文件路径和控制服务器地址替换为实际值。不要把账号密码或 JWT 放进 `ExecStart`；首次登录写入配置后，daemon 会在取得 device credential 后清掉配置中的用户 JWT，后续重启使用持久化的 device credential。查看服务日志使用：

`p2wlan-daemon` 会在首次成功连接控制面后把 device credential 持久化回配置文件，因此 `/etc/p2wlan` 必须由 `p2wlan` 用户可写；unit 已通过 `ReadWritePaths=/etc/p2wlan` 在 `ProtectSystem=full` 下显式放行该目录。

```bash
sudo journalctl -u p2wlan-daemon.service -f
```

systemd 实例的 TUN/route 权限由 unit 管理；CLI 的 `p2wlan up/down` 适合用户态、需要独立 PID/日志目录的运行方式，不要同时启动同一份配置。
