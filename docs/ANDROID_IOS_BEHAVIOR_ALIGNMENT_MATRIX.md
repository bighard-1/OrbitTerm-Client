# Android / iOS 行为对齐矩阵

更新时间：2026-08-21  
范围：移动端的操作结果、安全语义与数据变化；不以像素级或桌面布局一致为目标。  
状态：`已对齐`、`有意差异`、`待完成`。负责人中的“Android”指 Android 客户端实现与验收责任，“产品/安全”指需要明确产品或安全决策后才能改变的项目。

## 判定规则

- 两端必须对齐：凭据保存、主机身份验证、已验证会话门控、远端数据变更、同步冲突处理与危险操作确认。
- 可有意不同：系统文件选择、软硬键盘、后台执行、通知和 TalkBack / VoiceOver 的原生交互。终端分屏仅属于桌面端能力，不进入 Android/iOS 移动端。
- 任何 `待完成` 项都不能被描述为跨端已对齐；实现完成后需同时更新本矩阵、自动化覆盖和真实设备验收记录。

## 矩阵

| 域 | 操作结果 / 安全语义 | iOS 证据 | Android 证据 | 状态 | 负责人 | 验收条件 |
| --- | --- | --- | --- | --- | --- | --- |
| 认证 | 登录、注册、邀请码校验后建立加密会话 | `Features/Auth/AuthView.swift` | `app/AuthViewModel.kt`、`ui/LoginScreen.kt` | 已对齐 | Android | 登录、注册、失败与会话持久化均不展示密码或令牌。 |
| 认证 | 登录密码变更与主密码轮换分离；轮换中断可恢复 | `Features/Home/AccountSecurityView.swift` | `app/AuthViewModel.kt`、`app/MasterPasswordViewModel.kt` | 已对齐 | Android | 修改登录密码不改变主密码；主密码轮换后的本地提交失败保留可恢复状态。 |
| 账户安全 | 生物识别只用于解锁，不能替代主密码建立信任 | `Core/BiometricAuthService.swift` | `app/MainActivity.kt`、`app/MasterPasswordViewModel.kt` | 已对齐 | Android | 生物识别失败不解锁；锁定、登出与换账号清除内存主密码。 |
| 资产 | 资产新增、编辑、删除、分组、标签与搜索 | `Features/Home/ServerListView.swift` | `feature/assets/AssetsRoute.kt`、`AssetsViewModel.kt` | 已对齐 | Android | 搜索名称、地址、用户、分组和标签；分组默认折叠且状态稳定。 |
| 资产 | 批量导入、重复端点跳过与逐行错误隔离 | `AssetBulkAddSheet.swift` | `AssetBulkImportParser.kt`、`AssetsViewModel.kt` | 已对齐 | Apple + Android | 支持带引号逗号、Tab/分号格式；500 项/1 MB 上限；错误文案不回显密码或私钥。Android 对 Telnet 导入 fail-closed。 |
| 资产 | 保存前测试连接，不持久化草稿或遗留测试会话 | `AddServerView.swift` | `AssetsViewModel.testEditorConnection` | 已对齐 | Android | Host Key 仍需明确确认；成功后立即关闭临时会话；取消、锁定和迟到回调不得更新编辑器。 |
| 资产 | 最近删除的查看、恢复与永久删除 | `RecentlyDeletedView.swift`、`SyncQueue.swift` | `RecentlyDeletedViewModel.kt`、`SyncRepository.loadRecentlyDeleted`、`WorkManager` | 已对齐 | Android | 恢复前重新解密并校验资产身份；永久删除二次确认；无法解密的记录只能查看或永久清理；可重试网络失败进入账户隔离后台队列。 |
| 资产 | 分组长列表中可随时收起 | `ServerListView.swift` 的分组折叠 | `AssetsRoute.kt` 的 `stickyHeader` | 有意差异 | Android | Android 固定分组标题，方便触摸长列表；不改变分组或资产数据。 |
| 资产 | SSH 跳板机的独立凭据、独立主机密钥与最终会话复用 | `Core/JumpHostConfiguration.swift`、`SessionManager.swift` | `AssetsViewModel.kt`、`CheckedSshNativeClient.kt` | 已对齐 | Android | 先验证跳板、再验证目标；终端、SFTP、Docker、监控只使用最终已验证会话。 |
| 连接 | 首次信任、变更/撤销阻断、取消不建立会话 | `Core/HostKeyTrust/*` | `AssetsRoute.kt`、`CheckedSshNativeClient.kt` | 已对齐 | Android | 指纹可复制；变更、撤销和未知密钥均无绕过路径。 |
| 连接 | Telnet 仅能在明确风险确认后使用 | `SessionManager.swift`、`TelnetRiskConfirmationView.swift` | `AndroidTransportSupportPolicy.kt`；仅兼容同步保存，不提供连接或创建 | 有意差异 | 产品/安全 + Android | Android 明确不支持 Telnet，避免伪支持；同步进入的 Telnet 资产保留原始数据但 fail-closed，绝不降级为 SSH 或尝试连接。未来若支持，必须新增独立风险确认、禁用跳板/Host Key 混用、独立测试。 |
| 会话 | 多 SSH 会话选择、关闭、重连和迟到回调隔离 | `Core/SessionManager.swift` | `feature/terminal/TerminalSessionController.kt`、`OperationScopeCoordinator.kt` | 已对齐 | Android | 锁定、登出、切换账号或关闭会话后，迟到回调不能复活旧 UI 或 handle。 |
| 会话 | 在没有活动会话时仍能离开会话页 | `MainWorkstationView.swift` | `MainScreen.kt` 的 `shouldShowBottomDock` | 已对齐 | Android | 无会话显示底部导航；有活动终端时隐藏导航以保留可视高度。 |
| 终端 | 输入、ANSI 输出、滚动历史、回到底部、清屏、复制/粘贴与快捷键 | `SwiftTermTerminalView.swift`、`WorkstationTerminalSessionPane.swift` | `RemoteTerminalCanvasView.kt`、`TerminalClipboard.kt`、`TerminalSessionsRoute.kt` | 已对齐 | Android | 大输出无 ANR；复制/粘贴须由显式用户操作触发，敏感剪贴板按策略清理。 |
| 终端 | 移动端组合键、方向键与符号按显式使用频率稳定排序 | `MobileSessionViews.swift` | `TerminalSessionsRoute.kt`、`TerminalKeyUsageRepository` | 已对齐 | Apple + Android | 仅记录键标签与计数，不记录命令或终端内容；相同计数保持策划默认顺序。 |
| 终端 | 移动端单终端视图，多会话通过标签或切换器访问 | `MobileSessionViews.swift` | `TerminalSessionsRoute.kt` | 已对齐 | Apple + Android | Android 与 iOS 均不显示终端分屏入口；切换、关闭和状态提示完整可达。macOS/Windows 工作站分屏不属于移动端范围。 |
| 命令片段 | 分类、资产范围、变量提示、插入与直接执行、同步 | `SnippetsPanelView.swift` | `TerminalSessionsRoute.kt`、`SnippetSyncRequestBus.kt` | 已对齐 | Android | 受限片段不得对未授权资产执行；变量未填写不能下发。“快捷操作”只提供控制键与符号，不再内置重复命令模板。 |
| SFTP | 仅经已验证 SSH 会话进入目录；路径导航、浏览、应用内预览/编辑、未保存离开确认和快照冲突保护 | `SFTPBrowserView.swift`、`SFTPManager+FileOperations.swift` | `SftpRoute.kt`、`SftpInAppDocumentPolicy.kt`、`CheckedSftpNativeClient.kt` | 已对齐 | Apple + Android | UTF-8 文本可在应用内先预览后编辑；读取硬限制 2 MB；保存前校验原文件快照，冲突时保留本地草稿；编辑内容变化后关闭必须确认放弃；其他格式或超限文件使用下载处理。 |
| SFTP | 新建、重命名、chmod、删除与递归删除 | `SFTPBrowserView.swift`、`SFTPBrowserPanels.swift` | `SftpRoute.kt` | 已对齐 | Android | 所有变更使用 checked SFTP；递归删除有路径、深度、条目上限与显式确认。 |
| SFTP | 单文件/目录 ZIP 上传下载、FIFO、进度、取消与失败后继续 | `SFTPManager+Transfers.swift`、`SFTPBatchDownloader.swift` | `SftpRoute.kt` | 已对齐 | Android | Android 10/15 真机与真实服务器验证大文件、取消、队列、前后台和网络切换；结果写入 `ANDROID_REAL_DEVICE_TEST_RECORD.md`。 |
| SFTP | 多选文件与目录后一键批量下载/系统分享 | `SFTPBrowserView.swift`、`SFTPActivityShareSheet.swift` | `SftpRoute.kt` 的多选、checked FIFO ZIP、SAF 保存与 FileProvider 系统分享；`SftpShareArchivePolicyTest` | 已对齐 | Android | 多选项目始终归入同一 checked FIFO 传输；分享仅暴露短期应用私有 ZIP URI，不绕过取消、会话或账户作用域。 |
| SFTP | 文件系统交互 | iOS 使用 Files/分享表 | Android 使用 Storage Access Framework | 有意差异 | Android | Android 不申请宽泛存储权限；选择、写入和撤销均由 SAF URI 权限控制。 |
| Docker | 仅复用已验证 SSH 会话；列表、统计、日志、滚动、自动刷新和最新日志 | `DockerManagerView.swift`、`DockerLogStreamView.swift` | `DockerRoute.kt`、`CheckedDockerNativeClient.kt` | 已对齐 | Android | 会话切换取消旧刷新；长日志保持资源上限，不能显示旧会话数据。 |
| Docker | 启动、停止、重启、暂停、恢复、强制停止和删除 | `Core/DockerService.swift` | `DockerRoute.kt` | 已对齐 | Android | 危险的删除/强制停止均二次确认；操作中防重复提交。 |
| Docker | 容器改名与 `docker update` | `DockerManagerView.swift`（checked 模式同样拒绝） | Android checked Docker 未开放 | 有意差异 | 产品/安全 | 在 checked FFI 无类型、无注入风险的契约前，两端都不承诺此能力；不得回退到 shell 字符串拼接。 |
| 监控 | 绑定当前会话，CPU/内存/磁盘/网络采样、历史、暂停与错误态 | `MonitorDashboardView.swift`、`MonitorService.swift` | `MonitorPanel.kt`、`CheckedMonitorNativeClient.kt` | 已对齐 | Android | 切换会话后旧采样不可显示；刷新不造成内容跳动。 |
| 监控 | 客户端到当前资产 SSH 端口的 TCP 延迟与近 20 次样本丢包率 | `MonitorService.swift`、`MobileSessionComponents.swift` | `TcpLatencyProbe.kt`、`MonitorPanel.kt` | 已对齐 | Apple + Android | 目标必须是当前资产主机和实际 SSH 端口；连接失败记入丢包而不伪造延迟。 |
| 监控 | 最短采样间隔 | iOS 可选 1/2/5 秒 | Android 可选 2/5 秒 | 有意差异 | Android | Android 维持 2 秒下限以满足前台会话、电量及 100ms 帧基线；后续需在真机功耗证据支持后才可开放 1 秒。 |
| 同步 | 资产、跳板与命令片段加密同步；账户隔离和冲突选择 | `SyncService+Synchronization.swift`、`SyncService+Conflict.swift` | `SyncRepository.kt`、`ApplicationSyncCoordinator.kt` | 已对齐 | Android | 保留本地/云端的结果符合选择；跨账户、锁定、登出期间的旧任务不写入新作用域。 |
| 同步 | 资产页显式“立即双向同步” | `ServerListView.swift` | `AssetsRoute.kt` | 已对齐 | Apple + Android | 按钮只由用户触发；锁定或未登录时不绕过主密码，同步中有可访问的进度状态。 |
| 同步 | 独立 SSH 密钥库与保存的端口映射配置 | Keychain E2EE 合并、墓碑、账户隔离与移动端管理入口 | Keystore E2EE 合并、墓碑、账户隔离与移动端管理入口 | 已对齐 | Apple + Android | 本机专用密钥和正在运行的隧道状态不进入云端；包含 tunnel/process/running/auto-start 字段的映射信封继续拒绝；移动端只在前台且有已验证 SSH 会话时启动本地映射。 |
| 运维工具 | 移动端密钥管理、端口映射与批量命令均有可发现入口 | `MobileMoreView`、`MobileSSHKeyManagementView`、`MobilePortForwardingView`、`BatchCommandRunnerView` | `MainScreen.kt`、`SecurityToolsDialog.kt`、`AssetsRoute.kt` | 已对齐 | Apple + Android | 批量命令只对用户明确选定的 SSH 资产执行；未验证会话安全连接或显式失败。 |
| 同步 | 网络恢复后的可靠续跑 | iOS `SyncQueue` | Android `WorkManager` 与 `SyncWork.kt` | 有意差异 | Android | Android 后台任务不持有明文主密码；账户切换、锁定和登出取消旧作用域任务。 |
| 会话后台 | 允许短时保持活动会话 | iOS 受系统后台生命周期限制 | Android 前台服务与常驻通知 | 有意差异 | Android | Android 显示进行中通知、可全部断开、后台超时后安全关闭；旋转、锁屏、断网状态一致。 |
| 账户与诊断 | 主题、终端主题、诊断、帮助与反馈 | `SettingsView.swift`、`DiagnosticsExportView.swift` | `MainScreen.kt`、`OrbitTheme.kt`、`OrbitDesign.kt`、`OrbitDesignScreenshotBaselineTest.kt` | 已对齐 | Android | 应用主题不改变 ANSI 主题；诊断默认脱敏，不包含账户、主机、命令、路径、私钥或令牌；危险操作与固定视觉状态受语义/截图回归覆盖。 |
| 账户与诊断 | 移动端条款、隐私边界和邮件反馈入口 | `MobileSessionViews.swift` | `MainScreen.kt`、`AdministratorContactRepository` | 已对齐 | Apple + Android | 明确合法授权责任和诊断脱敏范围；Android 联系邮箱保留可由服务端刷新接口，离线使用安全默认值。 |
| 无障碍 | 安全状态不只依赖颜色；关键反馈有文本与语义 | iOS `AppAccessibilityPresentation.swift` | `OrbitDesign.kt`、`RemoteTerminalCanvasView.kt`、`TerminalSessionsRoute.kt`、`OrbitEmptyStateComposeTest.kt`、`P2AccessibilityLayoutRegressionTest.kt` | 待完成 | Android | 自动化验证标题/动态反馈语义、字体 200% 危险操作可达性、横屏布局与硬件键映射；仍须以 TalkBack、分屏和真实硬件键盘完成设备回归。 |

## 发布阻断与后续顺序

1. **P2 必做**：完成 TalkBack / 大字体 / 横屏验证。Android Telnet 已决定为不支持连接、兼容同步保存，不作为待发布功能。 |
2. **真机统一验收**：SFTP 大文件传输、取消、队列、进度与网络切换；该项继续以 `ANDROID_REAL_DEVICE_TEST_RECORD.md` 留档。
3. **发布演练**：仅在 P0/P1 门禁、上述 P2 必做项和真机记录具备证据后，更新发布清单为可发布。

## 维护约定

- 新增 iOS 或 Android 功能时，合并前必须新增或更新一行矩阵，并写明状态、负责人和验收条件。
- “有意差异”必须说明平台/安全原因；无法说明的差异一律列为“待完成”。
- 状态变化应附带源码路径、自动化测试名或真实设备记录，不以口头验证替代。
# Mobile personal center and asset editor alignment

Both mobile clients expose the same personal-center groups and order:
`账户与安全` → `设置与偏好` → `运维工具` → `帮助与信息` → `当前会话`.
Settings owns app/terminal appearance, connection protocols (including the
explicit Telnet risk gate), monitoring refresh, sync/recently-deleted and safe
diagnostics. Operations owns SSH keys, port forwarding and batch commands.

New assets default to password authentication on both platforms. SSH suggests
port 22 and permits key authentication plus a jump host. Explicitly enabled
Telnet suggests port 23, forces password authentication, disables jump-host
routing and exposes the same network-device profiles. A custom port is never
overwritten when the protocol changes.
