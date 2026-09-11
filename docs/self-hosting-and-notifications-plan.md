# P2WLAN 全端、自托管、Linux CLI 与发布部署完整实施方案

日期：2026-09-11。分析基线：v0.1.158 / 3e55ef4bab762dae5f3d82a60f64193747a1552c。
本文既记录 v0.1.158 基线审计，也记录本轮已经开始落地的实施约束。新增接口、命令、文件与版本命名只有在对应代码和 CI 通过后才算交付；未实测部分明确标注。
本轮用户指定 `47.109.40.237` 为后续 Actions 服务端部署测试目标，`~/.ssh/ali.pem` 为本地 SSH 私钥路径；它们不构成客户端默认服务器配置。业务代码、脚本和 CI 已开始修改，远端部署与正式发布仍需凭据和门禁证据。

## 1. 已核实的现状

- Flutter 的 `lib/core/models/diagnostics_models/app_settings.dart`、Rust daemon/CLI 的 `main.rs`、`client/android-native/src/lib.rs` 都有 `http://47.109.40.237:18080` 默认控制地址。
- `client/daemon/src/relay_runtime.rs::infer_default_relay_servers` 会把控制主机推导成 `tcp://同一主机:18081`；只删 Flutter 默认值不能消除隐式中继连接。
- `client/daemon/src/control/runtime/loop.rs` 收到空中继列表时会复用配置中的旧列表。需要区分用户配置、服务器目录和历史缓存，明确空列表语义。
- 已有持久化信令、HTTP 长轮询、ACK、设备认证 WebSocket 唤醒。`server/main.go` 注册了 `/api/v1/signals`、`/api/v1/signals/ack`、`/api/v1/signals/ws`；WebSocket 用于唤醒，信令正文由持久化接口消费。
- 已有 `server/api/relay_catalog.go` 结构化目录、设备注册下发目录、`/api/v1/relay/tickets` 票据签发、Relay 验签和撤销订阅。缺的是易用部署配置和完整管理流程，不是从零增加信令协议。
- `login_page.dart` 为错误保留固定 88 逻辑像素，再加 16 间距，造成密码框与按钮的大空白。这是上一版修复抖动时引入的布局代价。
- `shared/widgets/app_notice.dart` 已实现根 Overlay 中上方通知，多页面已使用；但目前只有通用样式、进入动画和单条替换，登录及用户名设置仍有独立错误展示。
- `.github/workflows/build-server.yml` 仅手动构建 Linux amd64 的 control/relay，上传保留 7 天的 Actions artifact；正式 Release 未包含服务端。
- SQLite 使用 `modernc.org/sqlite`。优先验证 `CGO_ENABLED=0` 的 Linux amd64/arm64 构建，不能照搬现有 CGO=1 配置或未经测试声称静态兼容。
- README 自托管章节只有源码构建入口，没有完整的安装、初始化、证书、启停、升级、备份和回滚步骤。
- CLI 登录仍强制邮箱并整体小写，与新版 GUI 支持用户名的行为不一致。

## 2. 目标与范围

新安装的所有客户端不预填或自动访问任何项目公共控制/中继服务器。用户先选择自己的控制服务器，再登录；中继只来自用户明确选择的模式及该服务器授权的配置。

沿用现有 control + signaling + relay 架构。同一 Linux 机器可安装控制面和中继，控制面包含信令；也允许分开部署。普通客户端不需要填写票据密钥。Relay 只持有验签公钥，签发私钥留在控制面。

本期交付完整自托管和静态授权中继目录。自动节点注册/租约管理是后续扩展，不应为了完成可部署自托管而重写信令系统。

## 3. 工作包 A：移除默认地址、梳理配置边界

1. 检查 Flutter、Android native、daemon、CLI、iOS 桥接入口、安装模板、构建参数与文档；生产默认控制地址为空，中继列表为空。不能换成另一个默认公网地址。
2. 新安装先展示“配置服务器”：地址输入、校验/连接检查、保存，然后进入账号登录；服务器入口不再藏在高级设置中。已配置时显示当前服务器并提供更换入口。
3. 将“允许保存未完成配置”和“允许发起在线操作”分开。设置可为空；登录、注册、在线启动必须明确验证服务器地址，空地址不进行网络请求。
4. 删除控制主机到 :18081 的自动推导。中继模式明确为：使用服务器目录（默认）、手动指定已授权节点、禁用中继。手动输入地址不能绕过 audience、票据或授权检查；无目录节点时仍允许已有机制支持的直连。
5. 服务器目录的显式空列表代表清空服务器来源节点；协议字段缺失表示旧协议，需要独立兼容分支。不能继续把已撤除的旧目录当作默认候选。
6. 新增配置版本和来源字段。历史值等于旧 IP 并不能证明用户未手工填写：保留为待确认数据，在下一次在线使用前确认或改填，不自动联系该地址，不静默抹掉自建配置。明确配置的新用户仍可手动填写这个 IP。
7. 规范化服务器身份，切换服务器时停止旧会话并隔离用户 token、设备凭据、账号展示、房间、信令与目录缓存；异步旧请求回调不能写回新会话。
8. 本期采用单个活动服务器，避免顺带开发多账号管理器。离线/手动模式保持独立，但不承诺现有协议不支持的离线房间或自动发现。
9. 对齐 CLI 邮箱/用户名登录规则：注册验证邮箱，用户名登录保留大小写。

验收：全新配置无默认远端请求；GUI/CLI/Android 空服务器行为一致；旧值升级可控；切换 A→B 不向 B 发送 A 的凭据；空目录清除旧服务器节点；禁用中继的直连用例仍通过。可选公共 STUN、更新检查须单独说明，不要把移除中继默认值表述为应用完全不联网。

## 4. 工作包 B：把已有信令与中继接入做完整

1. 增加版本/能力发现接口，例如 `/api/v1/server-info`，返回协议版本、服务端版本和公开能力。私有网络目录与凭据仍通过认证接口取得。
2. 服务端初始化工具生成 JWT 密钥、Relay 票据签发密钥/公钥、撤销订阅凭据和明确的节点 ID、audience、region、TLS 公布地址；沿用已有真实环境变量和字段。
3. 支持安装角色 control、relay、all。all 在同机部署两个独立服务，提供从初始化到客户端连接的完整默认流程；relay-only 必须导入控制面的授权配置及验签公钥。
4. 静态目录修改采用明确的校验与重载/受控重启流程；客户端重新获取权威目录，清除删除节点并失效相关票据缓存。不要宣传未实现的动态热更新。
5. 用现有信令传递设备会话与候选信息，继续保持 ACK、重试、过期、世代隔离与身份绑定；业务数据经加密直连或 Relay 转发。WebSocket 中断后长轮询仍能恢复。
6. 客户端呈现控制服务器、信令状态、中继模式、节点来源、当前路径与可操作错误。未启用 Relay、暂不可达、认证拒绝和没有可用路径应是不同状态。
7. 客户端手动指定节点时，按结构化节点身份申请票据；无受信任授权的任意 TCP 地址不能成为可用 Relay。
8. 新旧服务器能力不一致时给出升级提示。涉及后端新增能力必须实际升级用户部署的服务端才能生效；发布 APK 不能证明线上后端已经更新。

后续可选：受管理员授权的一次性接入凭据、Relay 主动注册与心跳租约、节点下线/撤销、目录版本通知。只有明确进入下一阶段才开发；此时必须增加防重放、身份固定和过期删除测试，不能允许任意客户端注册公共中继节点。

验收：全新 Linux 安装 control+relay；两台客户端登录同一服务器、加入房间；直连成功；屏蔽直连后经票据认证 Relay 通信；停 Relay 后状态正确；重启 control/Relay 后会话可恢复；过期票据、错误 audience、跨房间访问、被撤销设备均被拒绝。

## 5. 工作包 C：登录紧凑布局与全端统一提示

1. 删除登录 88 像素错误占位及页面内错误横幅；密码框与按钮间保留 16 逻辑像素，按钮保持现有稳定高度和加载内容尺寸。文案允许辅助功能要求下增长，不以裁切文字换取固定尺寸。
2. 扩展现有 `showAppNotice` 为统一入口：success/info/warning/error、标题、正文、关闭、可选操作。错误不进入表单布局，显示在可视安全区中上方。
3. 推荐规范：左右边距 16–20，最大宽度 460；距顶部在安全区内按可视高度定位，并限制为 24–96；进入/退出 150–200ms，淡入淡出加小幅位移。支持减少动态效果设置。
4. 按钮点击或一次请求结果触发通知，禁止在 build 或每次状态轮询中重复弹出。相同错误合并，限制队列；高优先级错误不得被“复制成功”立即挤掉。
5. 管理通知生命周期：定时器、Overlay 移除、路由/账号切换、连续替换及退出动画只清理一次；横竖屏、软键盘、大字体、桌面窗口缩放时不溢出、不遮挡关闭按钮，通知外部保持可交互。
6. 盘点 auth、settings、profile、rooms、nodes、dashboard、diagnostics、更新检查、深链等所有提示。操作结果统一为通知；删除/退出等确认保留可操作对话框并统一主题；列表空状态、持久故障说明保留在页面；系统 VPN 权限弹窗遵循系统样式。
7. 表单校验聚焦问题字段，保持辅助功能语义；技术错误映射为中文/英文可理解文案。不得把 token、密钥或原始堆栈显示给用户。
8. 登录状态只允许单个请求；处理 429 的 Retry-After（若服务端未提供，应补充响应头和测试），保留输入并限制再次提交，禁止自动重试登录造成持续限流。

验收：输入框与按钮间距符合设计；错误前/加载中/错误后位置稳定；成功、失败、警告、确认分别有截图；软键盘、大字体、窄屏/横屏、连续提示和路由退出不溢出、不遗留 Overlay。至少真机 Android 验证；模拟器/widget 测试不能冒充真机体验验收。

## 6. 工作包 D：服务端构建与独立正式发布

1. 新增服务端版本来源，与客户端分离；采用 `server-vX.Y.Z` 标签及独立 release-server 工作流。服务端发版不要求重构建客户端。
2. Linux amd64、arm64 分别产出 control+relay 包，含安装器、systemd 模板、配置示例、许可证、版本/提交/平台构建信息；control/relay 均提供 `--version`。
3. 产物建议命名 `p2wlan-server-linux-amd64.tar.gz`、`p2wlan-server-linux-arm64.tar.gz`。发布包外部提供 SHA256SUMS，先验证压缩包再解包；另有包内二进制校验值。
4. 构建并验证架构、最低 Linux 运行要求、动态库依赖。Go test/vet、跨架构运行验证和全新安装烟测纳入 CI。
5. 所有架构完成并校验前保持草稿，最后统一发布；正式发布标记 `make_latest=false`，避免服务端 Release 替代客户端 latest 下载目标。
6. 服务端更新器只筛选服务端标签及完整资产，客户端更新器只接受客户端版本；发布安全审计增加服务端资产入口，不能只检查客户端 Release。
7. 共用静态检查、依赖审计和构建配置，避免手动 Build Server 与正式发布使用两套不同构建逻辑。

验收：单独推送 server-v 标签只运行服务端发布链；两个架构安装运行；版本/提交/校验和一致；客户端 latest 不改变；服务端可独立更新并有兼容协议检查。

## 7. 工作包 E：安装、更新、运维命令

以下为拟定命令接口，实施后必须从发布资产中实际执行验证，不能提前写成 README 可用命令：

```bash
# 下载对应架构的服务端发布包和 SHA256SUMS，验证、解包后执行：
sudo ./install-server.sh --role all

# 安装后由管理命令提供：
sudo p2wlan-server init
sudo p2wlan-server status
sudo p2wlan-server update --version server-vX.Y.Z
sudo p2wlan-server update --latest
sudo p2wlan-server logs --service control
sudo p2wlan-server backup
sudo p2wlan-server rollback --version server-vW.Y.Z
```

- 安装器提供 amd64/arm64 检测、幂等执行、并发锁、清晰错误码。独立系统用户运行；二进制、配置和数据目录分离，例如 `/opt/p2wlan-server`、`/etc/p2wlan`、`/var/lib/p2wlan`。
- 私钥和订阅凭据使用受限权限文件；初始化只生成一次，更新不覆盖证书、JWT、票据密钥、数据库或用户配置，不将秘密放进命令行与日志。
- 提供 systemd 的 control 与 relay 独立单元、开机启动与失败恢复；更新只操作选定服务端单元，不重装客户端。
- 生产安装流程覆盖 HTTPS 反向代理与 Relay TLS、DNS/证书、监听地址、端口与防火墙说明。公网公布地址不得写成 0.0.0.0 或 localhost；裸 IP 必须有适用证书或明确开发模式。
- 更新按下载→外部校验→暂存→兼容检查→一致性备份→切换→启动→健康检查执行。失败保留可诊断信息并恢复兼容的旧版本。
- SQLite 备份使用在线备份机制或停服一致性快照，处理 WAL；不直接复制运行中的单个 DB 文件。数据库迁移必须说明可回退边界；不支持逆迁移时禁止自动把旧二进制配新数据库。
- 状态检查同时验证控制健康与 Relay TLS/认证就绪，不能只凭进程存在或 TCP 端口开放宣布成功。升级允许短暂断连，客户端自动恢复需测试，不能宣传零停机。

## 8. 工作包 F：README 与交付证据

同步 README.md 与 README.en.md：无默认服务器声明、用户首次配置、GUI/CLI 登录、下载表中的服务端包、自托管快速安装、单独升级服务端、版本兼容表、端口/TLS、数据路径、备份恢复、排障与完整文档链接。

新增 `docs/server-deployment.md` 和 `docs/server-upgrade.md`；命令、环境变量、文件路径、标签和包名必须与最终实现一致。不要让用户“阅读源码寻找生产参数”。

README 从全新机器完整执行一次，保存脱敏日志；发布链接、校验和、版本输出与截图形成验收记录。构建成功、Release 发布成功、实际服务器部署成功是三个不同结论，按证据报告。

## 9. Linux CLI 源码审计：优先修复的行为

以下为静态代码核实，不代表已经在 Linux 真机重现。实施者应先用回归测试固定相关路径，再修改。

| 优先级 | 现状与代码入口 | 修改要求 |
| --- | --- | --- |
| P0 | `client/cli/src/main/config/setters.rs` 修改 control 只清配置内凭据；`auth.rs` 的 `.session` 不绑定服务器，`rooms.rs` 会重新读取该 token 并向新服务器发送 | A 登录→切换 B→room list 必须保证 B 收不到 A 的 token；旧 sidecar 不能盲目绑定当前服务器，无法证明来源则要求重新登录 |
| P0 | `auth.rs::logout` 不停止主/房间 daemon，也不清房间副本凭据；撤销请求缺注册世代请求头，而 `server/auth/auth.go` 对新注册设备要求该证明 | 退出停止该账号本地实例、关闭自动重连、清账号及设备凭据副本；通过当前 daemon 的已认证控制入口完成设备撤销，或设计用户身份授权的设备撤销接口，不移除服务端世代校验 |
| P0 | `rooms.rs::leave_room` 在 owner 情况下直接 DELETE 房间 | 拆分 `room leave` 与 `room delete`；owner leave 提示先转让或显式删除。删除默认交互确认，脚本须显式 `--yes`，不能在兼容别名中保留静默删房间 |
| P1 | `daemon.rs::start_with_state_dir` 只接受非空用户 JWT；daemon 的 `control/runtime/loop.rs` 成功换取设备凭据后会清 JWT | 可用设备凭据允许重启；账号会话、设备认证、手动模式分开判断，不能为了 CLI 恢复而把用户 JWT 长期塞回 daemon |
| P1 | `auth.rs::authenticate` 强制包含 @，统一转小写，忽略服务端账号资料；还覆盖 diagnostics bind | 用户名/邮箱规则与 GUI 和服务端一致；保留显式端口设置；先验证服务器再读密码；统一账号资料模型 |
| P1 | `rooms.rs::disconnect_room` 先在线读取房间和 user_id；所有 room 子命令先 require_auth | 本地 status/logs/disconnect/doctor 根据本地索引工作，服务器离线、JWT 过期也能停止实例；在线修改成员关系仍须账号认证 |
| P1 | `paths.rs` 主实例运行目录是全局的；logs 不接收 config_path；房间诊断端口由 hash 对 20000 取模 | 所有命令共享实例定位；不同 --config 不共用 PID/token/log；端口冲突检测和可持久化分配，不能只认为 hash 足够唯一 |
| P1 | `daemon.rs` 启动超时可能留下子进程；down 发出退出请求即返回；PID 判定使用名称子串且 kill(pid,0) 的 EPERM 被当作不运行 | 生命周期加实例锁；核验进程、启动时间、配置身份；等待停止与本实例路由清理；失败状态必须可恢复，不误杀其他实例 |
| P1 | `diagnostics.rs` 的 status --json 失败仍打印中文；doctor 多种异常返回成功；`config/status.rs` 本地诊断 HTTP 未明确禁用环境代理 | 稳定 JSON/错误码，区分停止、无权限、token 错误和故障；本地 bearer 请求禁用代理与重定向，增加代理捕获回归用例 |
| P1 | CLI update 和 `scripts/install-linux-cli.sh` 未在解包前验证外部校验和；CLI 与 daemon 分次覆盖，无事务回滚 | 校验后解包，限制包内路径/链接，版本目录整体切换、锁和恢复；客户端与服务端更新器分别筛选版本 |
| P1 | updater 默认 /usr/local/bin，非 root 安装总走 sudo；只探测主 daemon，忽略房间/systemd 运行版本 | 根据实际安装清单定位；用户可写目录不提权；展示磁盘/运行版本及目标路径，显式选择重启范围，更新后核验所有选定实例 |
| P2 | 默认日志权限 0644；session 临时名固定；保存配置与 sidecar 分步完成；诊断输出主要是技术细节 | 日志默认私有或受控组可读；私密文件创建时即 0600、安全临时文件和锁；配置/会话有事务恢复；默认短摘要、--verbose 详细诊断 |

注意：注销时网络不可达，本地退出仍必须完成；远端撤销失败必须作为独立结果返回，不能宣称远端凭据已失效，也不能为重试无限保留登录凭据。需要提供重新认证后的远端设备管理路径。

## 10. 工作包 G：CLI 命令和输出契约

以现有命令渐进扩展，保留安全的 `start/stop`、`--email` 等别名。CLI、普通 daemon、服务端管理器的职责分开：`p2wlan up` 是客户端入网，不代表机器成为 Relay。

建议命令接口如下；现有同名命令的新增参数也需要实施，不可把整段当作现成命令执行：

```bash
# 首次配置与账号
p2wlan init --server https://control.example.com
p2wlan server show
p2wlan server check
p2wlan server set https://control.example.com
p2wlan login -u myname                 # 终端隐藏读密码
p2wlan login -u myname --password-stdin --non-interactive
p2wlan account show --json
p2wlan logout

# 当前客户端实例
p2wlan up --wait --timeout 30s
p2wlan status --json
p2wlan peers
p2wlan logs --follow --lines 100
p2wlan restart --wait
p2wlan down --wait
p2wlan doctor --strict --json

# 保存配置、有效配置与中继来源
p2wlan config show --effective
p2wlan config validate
p2wlan config set relay-source server  # server/manual/disabled
p2wlan config unset relay              # 清手动候选，不隐式切换路径策略

# 沿用现有房间控制命令，增加明确的本地生命周期和危险操作
p2wlan room join --code 12345678
p2wlan room connect 12345678
p2wlan room status 12345678 --json
p2wlan room logs 12345678 --follow
p2wlan room doctor 12345678 --strict
p2wlan room disconnect 12345678 --wait
p2wlan room leave 12345678
p2wlan room delete 12345678 --yes

# 安装管理和更新
p2wlan service install                # 安装受管理客户端实例，按需提权
p2wlan service status
p2wlan service uninstall              # 默认保留配置和身份
p2wlan update --check
p2wlan update --version vX.Y.Z --dry-run
p2wlan update --version vX.Y.Z --restart
p2wlan update --rollback
```

1. 全局参数统一 `--config`、`--json`、`--timeout`、`--non-interactive`、`--no-color`、`--verbose`。保留已支持的子命令位置语法。`--yes` 只跳过明确的产品操作确认，不补造缺失密码或服务器配置。
2. 非交互缺参立即退出，不等待 stdin/密码/sudo；只有显式 `--password-stdin` 才读密码流。弃用但短期兼容 `-p/--password`，文档移除明文密码示例；日志、错误、支持包不回显密码。
3. `stdout` 为数据、`stderr` 为进度/警告；JSON 模式禁用 banner、ANSI 和交互输出。非流式命令返回单个 JSON 对象，包含 `schema_version`、`ok`、`data`、`error`；错误含稳定 `code`、可读 `message`、可选 `retry_after_seconds`。日志跟随使用明确文档化的 JSON Lines。
4. 固定退出码：0 成功；1 未分类故障；2 参数/配置错误；3 认证失败；4 权限不足；5 网络不可达/超时；6 实例或资源冲突；7 健康检查未通过；8 更新/回滚失败；9 远端撤销等部分完成；130 用户取消。状态查询成功读到 stopped 可返回 0，`up --wait` 未就绪和 `doctor --strict` 必须非 0。
5. 状态分别呈现进程、设备认证、控制/信令、TUN/路由、各 peer 路径。`up --wait` 默认等待本机就绪，不等待不存在的 peer；需要双端连通由独立验收检查判断。
6. 统一账号模型和错误映射；429 按 Retry-After 提示，禁止自动登录风暴；401 提示重新认证，403 权限不足，409 世代/资源冲突，TLS/DNS/超时分别提示。账号请求、daemon 控制请求共享显式代理策略，本地诊断始终直连。
7. 命令帮助包含首次配置、实例选择、退出/删除区别及退出码；生成 bash/zsh/fish 补全。README 只放高频路径，完整参数在 `docs/linux-cli.md` 和 `--help`。

## 11. 工作包 H：CLI 内部结构、实例与安装生命周期

1. 建立一个实例上下文解析入口，输入配置路径、运行模式及可选房间 ID，输出配置/状态/log/token/PID 或 systemd unit。所有 status/logs/routes/support/update/down 共用，不能各自猜目录。
2. 配置路径先规范化；持久化安装/实例 ID，绑定所属 UID、配置位置和服务器/账号/房间身份。禁止通过任意未验证 PID 或 diagnostics URL 操作另一个实例；验证 TUN 和路由所有权后才能清理。
3. `P2WLAN_STATE_DIR` 等环境覆盖仍可用，但记录其实际位置并检测冲突。迁移旧运行目录前识别仍在运行的进程；不直接丢弃 PID 文件另起一份 daemon。
4. 用户实例与 systemd 实例采用明确 backend；同一配置只能由一个 backend 管理。`service install` 迁移须受控停止、设置所属用户和路径、启动验证；不是复制含 token 配置后把原进程留着。
5. 复用 `deploy/systemd/p2wlan-daemon.service` 的专用用户和 capabilities 设计。首次安装需管理员权限；日常读取可经受控本地接口，启动/停止按受限服务权限处理。不能配任意命令的 NOPASSWD sudo 来省事。
6. 无 systemd 环境保留手动 daemon 模式并输出准确引导。首期必须验证 Ubuntu/Debian；ARM64 验证包可运行；musl/Alpine、NAS、非 systemd 发行版只能在验证后列为支持。
7. 账号 session 用版本化结构保存来源服务器、用户 ID、有效期与 token；账号资料独立于 daemon 设备凭据。新旧 JSON/sidecar 并存迁移必须能检测半写入、并发覆盖和错误服务器；未知来源不推断成当前服务器。
8. 配置修改有校验、差异、是否需重启标记；不实现伪热更新。relay-source 与 path-policy 为不同维度：disabled + relay-only 等矛盾组合应拒绝并给出改法。
9. 多房间保持现有独立节点身份；本地索引记录 ID/code、账号服务器、配置和 backend。只按本地记录可停止目标；路由网段冲突、诊断端口占用、重复启动须在改变系统网络前明确报错。
10. 安装清单记录产品、版本、架构、安装根目录、binary pair 与服务模式；升级以版本目录加 current 指针整体切换，保留前一套，不覆盖运行中可执行文件。服务端与客户端清单互不覆盖。
11. 解包前验证发布校验和，拒绝路径穿越、越界软链接及缺少必要二进制的包；临时目录安全创建并保证失败清理。更新锁、磁盘不足、下载中断、第二个文件安装失败、重启失败都必须可恢复。
12. 更新默认展示将改变的实例；`--restart` 才执行明确范围内的重启，否则报告“文件已更新，运行版本尚未更新”。多个房间和 systemd 进程分别核验，不能只比较 CLI 的 package version。
13. 卸载默认只移除程序/服务，停止自己管理的实例并清理所属路由；删除账号/配置/数据需独立显式选项。服务端数据库不能因客户端卸载被删除。

## 12. 工作包 I：所有端账号展示与 Android 体验闭环

1. GUI 已有 UsernameSettings 和账号缓存，应在现有链路上补齐。账号区固定显示用户名、邮箱（如有）、用户 ID、当前服务器及会话状态；无用户名显示“未设置”，离线显示已缓存身份和“尚未在线验证”。设备凭据可用不等于用户会话仍有效。
2. `settings_page/account.dart` 当前仅 authToken 非空时构建用户名区；审查 token 过期、手动凭据和账号缓存场景，不能整个隐藏身份。CLI account show 使用同一语义；不能把 token/公钥当作用户名。
3. 登录/资料刷新/应用重启/深链切服/退出同走会话隔离入口；旧请求不能覆盖新账号。Windows、macOS、Linux GUI、Android 及项目支持的 iOS 构建均纳入测试范围，缺少设备单列未实测。
4. Android `MainActivity.kt` 已有按当前分辨率选择最高不超过 120 Hz 支持模式的逻辑，不能把再设置一次 120 当完成任务。复核 resume、窗口变化、系统省电/自适应刷新、60/90/120 Hz 回退和外接显示切换。
5. 用 release/profile 模式测登录、通知、账号、房间列表滚动与状态刷新；采集 Flutter build/raster 帧耗时及真机显示模式。120 Hz 帧预算约 8.33ms，记录 P50/P95/P99 和慢帧占比；系统选择 60 Hz 时明确记录原因，不虚报持续 120 FPS。
6. 大列表懒构建、缩小状态订阅范围、合并高频 diagnostics 更新；不要为 UI 每帧轮询网络或频繁跨 FFI/JNI。只根据实测瓶颈优化，网络心跳/信令及时性不因降刷新被破坏。
7. 登录错误紧凑布局和全端通知按工作包 C 实施；统一排查 showDialog、SnackBar、Toast、Overlay、页面内错误等入口并建立场景清单。账号显示和 Android 帧率是发布验收项，不能只跑服务端后遗漏。

## 13. 工作包 J：Actions 构建、上传阿里云并集成测试

### 13.1 目标与凭据

- 目标主机：用户指定的 `47.109.40.237`。本地 SSH 使用 `~/.ssh/ali.pem`；SSH 用户、端口、主机架构、当前服务/数据库位置、域名和 TLS 配置在实施首步只读盘点。不能凭 IP 假定 root 用户或直接覆盖正在服务的实例。
- 本轮未连接该主机，也未读取私钥内容。实施时本地私钥不进仓库、日志、安装包、Actions cache/artifact；GitHub 托管 runner 无法直接读取本机 `~/.ssh/ali.pem`。
- 建议用现有本地 SSH 权限初始化专用部署账号和 CI 专用密钥，CI 私钥放 GitHub Environment secret `STAGING_SSH_PRIVATE_KEY`，变量设 `STAGING_HOST`、`STAGING_USER`、`STAGING_PORT`。如决定复用现有密钥，只经安全 secret 输入通道配置，不复制到 workflow 文本。
- 核验 SSH 主机指纹并固定 known_hosts；不能只运行未经核验的 ssh-keyscan 后无条件信任，也不能关闭 StrictHostKeyChecking。部署账号只操作测试版本目录和限定 service；不要给 runner 任意 root shell 权限。
- 部署初期采用独立 `p2wlan-staging-control` / `p2wlan-staging-relay`、独立数据/日志/端口和专用测试账号；先完成端口/资源预检。若现机资源不满足隔离，报告具体冲突后调整环境，不能为了测试停现有业务服务。
- HTTPS/Relay TLS 使用已配置的真实域名或受测试客户端显式信任的测试证书；IP 是 SSH 目标，不要求生产 API 证书必须签给 IP。不得全局关闭 TLS 校验。

### 13.2 流水线设计

```text
可信提交 SHA
  → 静态检查 / 单元 / 协议兼容测试
  → Linux amd64 + arm64 构建、运行烟测、外部校验和
  → 暂存同一批产物（记录 SHA、架构、版本、digest）
  → 部署 job 下载指定 run 的产物并再次校验
  → SSH 预检、上传版本目录、服务端管理器受控切换
  → 健康检查 + 两客户端业务集成 + 故障恢复/升级验证
  → 上传脱敏证据
  → 服务端标签发布时，将已验证的同一产物转成正式 Release
```

1. 使用共享构建脚本/可复用 workflow 整理现有 build-server，增 `server-integration` / `deploy-staging` / `release-server` 职责；名称可调整，但不可每条流水线采用不同构建参数。
2. PR 跑不接触 secret 的构建与隔离集成测试；云机部署只允许可信分支及手动指定可信 commit，禁止不受信任 PR/fork 获得部署凭据，禁止以 pull_request_target 执行未审查代码后携带 secret。
3. 主机部署设 concurrency，部署到健康检查结束同一把锁；不要自动 cancel 已开始切换的部署。部署超时必须恢复或留下清晰可接续状态。手动失败重跑也要识别已上传版本，不能覆盖另一个 run。
4. 权限按 job 最小分配；只有正式发布 job 拥有 contents:write。外部 actions 固定 SHA，shell 输入参数校验和正确引用，禁止把未验证 ref/版本拼入远端 shell。
5. 若云机出网有限，runner 上传已经构建且校验的离线包，云机不编译源码、不再次拉取浮动 latest。状态输出必须核对运行中的 control/relay build SHA 和上传 digest。
6. 测试失败时整个部署测试 job 失败，采集脱敏日志后恢复上一测试版本；不能用 continue-on-error、忽略 SSH 状态码或仅端口通就宣告成功。记录回滚也失败的情况。
7. 正式发布必须等集成门禁通过；Release 草稿资产齐全后再公开。客户端 `v*` 和服务端 `server-v*` 的 tag 触发条件、版本来源和 latest 选择独立，交叉触发写自动化回归测试。

### 13.3 云机验证必须覆盖的场景

- 全新安装、重复安装幂等；control-only、relay-only 和同机 all 的配置校验；版本输出、配置权限、systemd 重启和服务器重启恢复。
- 两个测试客户端注册/登录、资料读取、创建/加入房间、设备注册、信令收发/ACK、端到端加密收发；通过真实 CLI 和 daemon 执行，不能仅 curl health。
- 可直连拓扑明确验证 Direct；受控禁止客户端间直连时验证 Relay 双向有效载荷，核对 path 状态和字节计数。防火墙规则仅作用于隔离 namespace/测试实例，不能修改宿主全局 DROP 或 SSH 规则。
- 错误/过期票据、audience 错误、跨房间、设备撤销、节点移除、服务器空目录、无 Relay 的直连、WebSocket 断开后持久化轮询恢复。
- 重启 control/relay、客户端网络中断与恢复、重复信令/ACK、旧注册世代拒绝；检查之前 `relay_confirmation_missing` 相关链路，保存两端关联日志。
- CLI 离线 room disconnect/logout、多个 --config 隔离、用户安装更新、systemd 受管启动、运行中更新、升级失败回滚。
- 从上一个发布服务端版本升级，账号/房间/节点密钥/数据保留；SQLite WAL 一致性备份恢复；数据库迁移不兼容时拒绝不安全回滚。
- 云机提供真实公网部署验证，Linux namespaces 提供可重复网络故障验证；单一公网机器不能证明所有 NAT 类型与手机运营商网络。Android 真机和现有 NAT topology gate 都须保留。

证据至少包含：Actions run URL、源码 SHA、资产 SHA256、云机架构、运行版本、各用例结果/耗时、失败诊断和恢复状态。测试密码、账号 token、SSH key、JWT/Relay 私钥和有效邀请不能进入日志；测试清理只删除带当前 run ID 的资源。

## 14. 文档、测试矩阵与最终交接顺序

README.md / README.en.md 同步更新并链接以下文档：

- `docs/linux-cli.md`：普通用户初始化、用户名/邮箱登录、账号状态、房间命令、后台模式、systemd、退出码、JSON、代理、权限和更新。
- `docs/server-deployment.md`：架构与角色、安装包校验、首次初始化、配置真实字段、端口/TLS、独立 Relay 接入、客户端手工配置。
- `docs/server-upgrade.md`：独立版本、更新/回滚、备份恢复、数据库和客户端协议兼容范围。
- `docs/staging-validation.md`：Actions 参数/secret 名称、SSH 指纹初始化、隔离目录/服务、用例和证据收集；不写秘密值。
- `docs/notifications.md`：各场景使用通知/字段校验/确认框/持久状态的规则和验收截图索引。

当前 `.gitignore` 忽略绝大多数 `docs/*`，且忽略 `deploy/staging/*.env.example`。实施时给交付文档及脱敏示例增加精确白名单，确认 git ls-files 能列出它们；真实 .env、私钥和数据库继续忽略。不能只在本地创建 README 引用的文件却没有提交。

| 门禁 | 必须验证 |
| --- | --- |
| Rust / CLI | fmt、clippy、相关 workspace tests；跨服 token 不泄露、设备凭据重启、离线停止、JSON 错误、世代撤销、实例隔离、恶意压缩包和更新故障恢复 |
| Go / 服务端 | fmt、vet、tests；Linux 原生适用的 race tests；票据/信令/权限/版本兼容与备份升级 |
| Flutter / Android | analyze、widget/unit/integration；账号缓存隔离、无默认远端、通知布局、429 状态；Android release/profile 真机交互与帧耗时 |
| Linux 系统集成 | amd64/arm64 可运行产物；TUN/route、双房间、普通用户提权、systemd、离线操作、干净安装/升级/卸载保留数据 |
| 发布及远端 | 最终 SHA 全部必需 CI；阿里云同产物集成；客户端/服务端 Release 隔离、资产完整、校验和、恢复记录 |

推荐让实施模型按以下顺序逐包完成；每包必须交付修改、对应测试和结果，不可把多个包混成一次无边界重写：

1. **P0 身份与破坏性语义**：修 CLI 跨服 sidecar、logout 生命周期/撤销及 owner leave；补回归测试。先阻止泄露和误删。
2. **统一配置与账号**：A、G 的认证/账号契约、I 的全端身份展示；去默认值、来源与迁移；统一错误协议。冻结服务器身份/账号结构，供后续使用。
3. **CLI 生命周期**：H 的实例解析、G 的本地命令/JSON/退出码；设备凭据重启、离线房间操作、systemd 路径、权限、诊断和多实例冲突。
4. **服务端与信令闭环**：B 的能力协商、初始化/目录/票据接入；补控制面与客户端兼容及 NAT 信令回归。保留现有协议，不自行引入第二套信令系统。
5. **全端交互**：C 和 I 的登录、通知、账号、Android 实测性能；与核心协议调整互不掩盖验收结果。
6. **安装更新**：D/E/H 的双产品安装、版本目录、校验、systemd、备份恢复；先测试失败路径再接自动发布。
7. **Actions 和云机**：J 的构建→上传→隔离部署→业务测试→恢复，完整验证后把相同产物纳入 server release。
8. **文档及发布**：F 和本节的双语 README、完整文档、命令实跑；最后提交 SHA 跑齐门禁，客户端和服务端各自按实际变更发版。

每个工作包单独提交，遵循仓库 `feat:中文` 格式；说明修改文件、行为、测试和未完成项。禁止删除门禁、放宽断言、把 skip 当 pass、以反复重跑替代定位重复失败。

历史 NAT CI 曾出现重复 `relay_confirmation_missing`：抓取的失败日志中，响应方记录发送握手应答成功，而发起方缺少应答处理并最终超时。最终重跑通过不能解释该问题。本期全链路验收须复核信令持久化/唤醒/消费/ACK 到握手处理过程，重复失败必须保留证据并修复后再宣称可靠。

最终验收以最后提交 SHA、完整 CI 结果、服务端发布资产、干净安装/独立升级记录以及 Android 实际交互证据为准；没有设备或部署权限时明确标注未实测，不代替用户确认结果。
