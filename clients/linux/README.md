# OrbitTerm Linux Client

OrbitTerm 的原生 Linux 桌面客户端。界面使用 GTK 4、libadwaita 与 VTE，网络能力复用仓库中的 Rust `orbit-core`，不复制 SSH/SFTP/Docker 协议实现。

## 当前可运行范围

- 三栏工作台：服务器资产、终端工作区、SFTP/Docker/片段工具区。
- XDG 目录中的非敏感资产持久化，文件权限为 `0600`，目录权限为 `0700`。
- Secret Service（GNOME Keyring/KWallet 兼容接口）中的密码、私钥与私钥口令存储。
- `orbit-core` checked ABI 的 SSH 连接、首次 Host Key 指纹确认、专用 `known_hosts` 持久化与终端 PTY。
- 密码或系统文件选择器导入 SSH 私钥的资产创建流程。
- 搜索、添加资产、终端输入、异步输出，以及显式断开/重连。
- 每 5 秒采样的 Monitor 指标（延迟、CPU、内存）。
- SFTP 目录导航及最大 2 MiB 的只读文本预览。
- Docker 容器列表、资源统计、最近日志、重启与停止操作。
- 与 Apple/Android 同源协议的云端登录、令牌刷新、账户隔离增量拉取、游标失效恢复、安全预览、新增资产导入与同步确认回执。
- 可操作的冲突解决中心：逐字段比较本机/云端，支持采用云端、保留本机、接受删除与恢复云端。
- 离线同步操作队列：待上传/待恢复请求先以 `0600` 原子文件持久化，支持请求去重、幂等重试、失败原因、退避时间线和按条/全部手动重试。
- 应用级自动恢复调度：启动、网络重新可用及退避到期时自动处理当前账户的队列；同步中心打开时暂停后台执行，并通过单飞门避免并发重放。
- 安全同步会话：主密码只进入进程内 `Zeroizing` 内存，解锁 30 分钟后、账户切换、显式锁定、退出或应用关闭时清除；不会写入 Secret Service、XDG 文件、日志或通知。
- 后台增量拉取：解锁期间每 30 秒检查增量；无冲突变更安全写入资产仓储与 Secret Service 后确认游标，冲突、墓碑、失败和排队项则停止确认并发送去重桌面通知。
- 同步健康状态：侧栏持续显示未登录、主密码锁定、后台拉取、健康修订、等待退避、人工处理和令牌保存异常。
- 账户退出与切换：退出会清除 Secret Service 中的访问/刷新令牌、内存主密码和待展示预览。正式 API 尚未提供远端令牌撤销端点，因此界面不会把本地清除伪称为服务端撤销。

任何尚未接线的操作都保持不可用状态，不会退回 legacy 或 accept-all 网络路径。

## 工程分层

```text
crates/
├── orbit-linux-domain       # 可同步的非敏感领域模型与校验
├── orbit-linux-application  # 用例与仓储接口
├── orbit-linux-bridge       # orbit-core checked ABI 的唯一调用边界
├── orbit-linux-platform     # XDG、原子文件写入、Secret Service
├── orbit-linux-sync         # HTTPS、令牌刷新、portable 解密与安全预览
└── orbit-linux-app          # GTK/libadwaita/VTE 桌面界面
```

界面不得直接声明 FFI；平台层不得保存明文凭据；桥接层不得调用 legacy connect/SFTP/exec API。

## Ubuntu 24.04 开发环境

```bash
clients/linux/scripts/install_dev_dependencies_ubuntu.sh
clients/linux/scripts/check_linux.sh
clients/linux/scripts/run_linux.sh
```

最低开发工具链为 Rust 1.92。当前已验证目标为 Ubuntu Desktop 24.04 x86-64、GNOME 46、Wayland/XWayland。

## 本地数据

遵循 XDG Base Directory：

- 资产：`$XDG_DATA_HOME/OrbitTerm/assets.json`
- Host Key：`$XDG_STATE_HOME/OrbitTerm/security/known_hosts`
- 设备 ID、按账户隔离的同步游标，以及逐资产远端 ID/向量时钟/状态/服务端修订：`$XDG_STATE_HOME/OrbitTerm/sync/state.json`
- 按账户隔离的离线操作与审计时间线：`$XDG_STATE_HOME/OrbitTerm/sync/operations.json`（只含密文上传负载，不含主密码、令牌或明文凭据）
- 凭据：桌面 Secret Service，schema 为 `com.orbitterm.Client.Credential`
- 云同步令牌：桌面 Secret Service，schema 为 `com.orbitterm.Client.AuthToken`

缺少 XDG 环境变量时使用标准的 `~/.local/share`、`~/.local/state`、`~/.config` 与 `~/.cache` 回退。凭据永远不进入资产 JSON 或日志。

## 跨端同步边界

Apple 与 Android 已使用 `https://server.orbitterm.com/api/v1` 的认证、端到端加密配置、稳定资产 UUID、向量时钟、删除墓碑和冲突恢复协议。Linux 当前已启用安全增量拉取：支持账户登录、401 刷新、Secret Service 令牌保存、与 Apple 相同的 JWT `uid` 账户指纹、每账户独立游标、稳定设备 ID、100 项分页、一次 `reset_required` 回退、主密码解密、portable 校验、只读预览及远端新增资产导入。

同 UUID 项和涉及本地资产的远端删除墓碑会进入冲突解决中心。活动记录展示名称、分组、标签、主机、端口、用户、认证方式与密码回退的本机/云端对比；用户必须逐项选择“保留本机”或“采用云端”。删除墓碑必须选择“接受删除”或“恢复云端”。解密失败项和 Linux 尚不支持的 Telnet 项保持阻断，不允许推进游标。

“保留本机”沿用远端记录 ID、资产 UUID 与身份指纹，以本机稳定设备 ID 推进向量时钟，并将本机 portable 配置用本次主密码重新加密后上传；“恢复云端”使用稳定操作 UUID 调用恢复端点。“采用云端”与“接受删除”只改变本机资产文件和 Secret Service。四类动作均在成功后记录逐资产远端修订；非敏感本机字段摘要用于识别后续本机编辑，避免旧修订掩盖新冲突。远端写入返回的新修订不会越过本批拉取检查点，仍由下一次增量拉取复核。

离线队列不依赖主密码重新执行，因为持久化内容已经是端到端加密负载或稳定恢复请求。应用启动后从 Secret Service 读取当前账户令牌，按账户指纹检查到期操作；网络恢复信号和 5 秒安全定时器只负责唤醒，同一时刻最多存在一个后台执行器。401 刷新后的令牌重新写入 Secret Service；同步中心打开期间后台调度暂停，所有人工动作继续走同一队列与幂等执行路径。

用户使用账户登录或已保存令牌完成一次可解密预览后，Linux 建立仅限当前进程的主密码解锁会话。后台每 30 秒执行账户隔离增量拉取；只在整批没有冲突、墓碑决策、解密失败或排队资产，且所有本地资产、凭据和逐资产修订写入成功后，才发送 acknowledgement 并保存游标。需要人工处理时，预览保留在零化内存中并通过 `GNotification`/桌面 portal 提醒，点击通知打开同步中心；同一账户、修订与问题数量只提醒一次。

只有本批没有待处理记录、所有本地资产/凭据/逐资产修订写入全部成功后，Linux 才调用 `/config/sync/ack` 确认原始服务端检查点，并以原子方式保存账户游标。服务端不支持增量端点时可回退全量导入，但不发送确认、不保存游标。

同步确认回执只确认“Linux 已安全处理到某个修订”。冲突动作中的“保留本机”和“恢复云端”会按用户明确选择修改云端；其余确认过程不会隐式上传、删除或覆盖云端配置。待上传与待恢复动作会在首次发送前持久化，以账户指纹和请求哈希去重；失败后按 10/30/120/300/600/900/1800 秒退避，并保留原因、尝试次数和时间线。队列未清空前，相应资产保持阻断且同步游标不推进。主密码、令牌、明文密码和私钥均不写入队列文件。

真实账户的跨端步骤、证据字段和 Windows 当前阻断项见 [`docs/testing/CROSS-PLATFORM-SYNC-MATRIX.md`](../../docs/testing/CROSS-PLATFORM-SYNC-MATRIX.md)。
不需要账户凭据的重启恢复、5xx、401、连接拒绝、重放和 fail-closed 验证见 [`docs/testing/LINUX-SYNC-FAULT-MATRIX.md`](../../docs/testing/LINUX-SYNC-FAULT-MATRIX.md)，可通过 `scripts/run_sync_fault_matrix.sh` 生成脱敏证据。

现有跨端协议会在本机从 Secret Service 读取凭据，组装 portable 配置后以主密码加密，再上传密文。Linux 本地领域模型仍不表示凭据；拉取模块在内存中解密后立即把资产元数据和凭据拆分，凭据写入 Secret Service，任何明文都不得写入资产文件或日志。

## 发行策略

- Flatpak：面向不同发行版和版本的主渠道，固定运行时并通过 portal/Secret Service 集成桌面。
- `.deb`：Ubuntu 24.04/Debian 系的原生补充包。
- 原生 tarball：供受控企业镜像使用，明确声明 glibc、GTK、libadwaita 与 VTE 基线。

不以单个 AppImage 宣称覆盖所有 Linux：密钥环、portal、Wayland 和系统库组合需要可测试的运行时边界。
Flatpak 清单固定 GNOME 运行时，并将 VTE 终端库作为带 SHA-256 校验的应用模块构建，避免依赖宿主发行版的 VTE 版本。

## 安全基线

- 未知 Host Key 必须展示 SHA-256 指纹并由用户核对。
- changed/revoked/unsupported Host Key 必须阻断。
- 终端、SFTP、Monitor、Docker、Batch 只接受已有 `HostKeyVerified` 基础会话。
- 所有 checked envelope 校验 `schema_version`、`request_id`、`kind` 和 `data/error` 互斥结构。
- release gate 扫描并拒绝 legacy 网络符号。
- 云同步固定 HTTPS 正式端点，限制响应为 32 MiB、库存为 10,000 项、单个密文为 4 MiB，并对超时/连接错误和 5xx 执行有限退避重试。
- 同步游标只有在无冲突、无解析失败、本地写入全成功且服务端确认成功后推进；账户身份无法从 JWT `uid` 验证时拒绝使用游标。
