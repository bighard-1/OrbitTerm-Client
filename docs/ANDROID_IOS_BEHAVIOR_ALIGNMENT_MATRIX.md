# Android / iOS 行为对齐矩阵

更新时间：2026-09-01
范围：移动端的功能、信息架构、视觉层级、操作结果、安全语义与数据变化；追求品牌与布局高度一致，不复制非原生控件。
状态：`已对齐`、`有意差异`、`待完成`。负责人中的“Android”指 Android 客户端实现与验收责任，“产品/安全”指需要明确产品或安全决策后才能改变的项目。

## 判定规则

- 两端必须对齐：凭据保存、主机身份验证、已验证会话门控、远端数据变更、同步冲突处理与危险操作确认。
- 可有意不同：系统文件选择、软硬键盘、后台执行、通知和 TalkBack / VoiceOver 的原生交互。终端分屏仅属于桌面端能力，不进入 Android/iOS 移动端。
- 任何 `待完成` 项都不能被描述为跨端已对齐；实现完成后需同时更新本矩阵、自动化覆盖和真实设备验收记录。

## 矩阵

| 域 | 操作结果 / 安全语义 | iOS 证据 | Android 证据 | 状态 | 负责人 | 验收条件 |
| --- | --- | --- | --- | --- | --- | --- |
| 认证 | 登录、注册、邀请码校验后建立加密会话 | `Features/Auth/AuthView.swift` | `app/AuthViewModel.kt`、`ui/LoginScreen.kt`、`AuthValidationTest.kt` | 已对齐 | Android | 两端在提交前校验邮箱与 12 位组合密码；冷却期显示剩余秒数并禁用按钮；会话持久化不展示密码或令牌。 |
| 认证 | 登录/注册法律同意区在窄屏保持单行，并完整说明条款、免责声明与隐私说明 | `Features/Auth/AuthView.swift` | `ui/LoginScreen.kt`、`MobileRootStateComposeTest.kt` | 已对齐 | Apple + Android | 可见文案固定为“已阅读并同意 / 查看法律条款”，不得换行或截断；完整法律名称保留在无障碍标签与说明弹窗。 |
| 认证 | 登录密码变更与主密码轮换分离；轮换中断可恢复；操作状态、回执和迟到回调隔离 | `Features/Home/AccountSecurityView.swift`、`SecurityOperationPresentation` | `app/AuthViewModel.kt`、`app/MasterPasswordViewModel.kt`、`SecurityOperationPresentation.kt` | 已对齐 | Apple + Android | 修改登录密码不改变主密码；两类操作的错误不得串台；忙碌时禁止重复提交；成功回执 4 秒后消失，失败持续显示；页面离开、锁定、登出或换账号后的旧回调不得更新新状态；主密码轮换后的本地提交失败保留可恢复状态。 |
| 账户安全 | 退出登录前明确确认且不误导为删除本机加密数据 | `MobileSessionViews.swift`、`SecurityOperationPresentation` | `MainScreen.kt`、`SecurityOperationPresentation.kt` | 已对齐 | Apple + Android | 两端固定显示“退出登录？”及会话断开、登录状态清除、加密数据按账户隔离保留的影响说明；取消不改变账户状态。 |
| 账户安全 | 生物识别只用于解锁，不能替代主密码建立信任；注册失效后关闭旧开关并要求主密码恢复 | `Core/BiometricAuthService.swift`、`MasterPasswordGateView.swift` | `app/MainActivity.kt`、`app/MasterPasswordViewModel.kt` | 已对齐 | Apple + Android | 前台进入锁定页时每轮至多自动请求一次；验证中禁止重复提交；取消保持安静，锁定/不可用/失败使用固定文案；系统生物识别集合变化或受保护密钥缺失时不得自动重建，必须先用主密码解锁并由用户重新启用；成功回执 4 秒后消失，失败和恢复提示持续保留。 |
| 资产 | 资产新增、编辑、删除、分组、标签、搜索与主要点按 | `Features/Home/ServerListView.swift` | `feature/assets/AssetsRoute.kt`、`AssetsViewModel.kt` | 已对齐 | Apple + Android | 搜索名称、地址、用户、分组和标签；分组默认折叠且状态稳定；服务器卡片单击即连接，编辑保留独立入口。 |
| 资产 | 批量导入、重复端点跳过与逐行错误隔离 | `AssetBulkAddSheet.swift` | `AssetBulkImportParser.kt`、`AssetsViewModel.kt` | 已对齐 | Apple + Android | 支持带引号逗号、Tab/分号格式；500 项/1 MB 上限；错误文案不回显密码或私钥。Android 对 Telnet 导入 fail-closed。 |
| 资产 | 保存前测试连接，不持久化草稿或遗留测试会话 | `AddServerView.swift` | `AssetsViewModel.testEditorConnection` | 已对齐 | Android | Host Key 仍需明确确认；成功后立即关闭临时会话；取消、锁定和迟到回调不得更新编辑器。 |
| 资产 | 最近删除的查看、恢复与永久删除；加载、旧记录保留、失败重试和排队回执使用统一状态契约 | `RecentlyDeletedView.swift`、`RecentlyDeletedPresentationMapper`、`SyncQueue.swift` | `RecentlyDeletedViewModel.kt`、`RecentlyDeletedPresentation`、`SyncRepository.loadRecentlyDeleted`、`WorkManager` | 已对齐 | Apple + Android | 恢复前重新解密并校验资产身份；永久删除二次确认；无法解密的记录只能查看或永久清理；可重试网络失败进入账户隔离后台队列；失败持续显示且不清空旧记录，成功或排队回执 4 秒后消失。 |
| 资产 | 分组长列表中可随时收起 | `ServerListView.swift` 的分组折叠 | `AssetsRoute.kt` 的 `stickyHeader` | 有意差异 | Android | Android 固定分组标题，方便触摸长列表；不改变分组或资产数据。 |
| 资产 | SSH 跳板机的独立凭据、独立主机密钥与最终会话复用 | `Core/JumpHostConfiguration.swift`、`SessionManager.swift` | `AssetsViewModel.kt`、`CheckedSshNativeClient.kt` | 已对齐 | Android | 先验证跳板、再验证目标；终端、SFTP、Docker、监控只使用最终已验证会话。 |
| 连接 | 首次信任、变更/撤销阻断、取消不建立会话 | `Core/HostKeyTrust/*` | `AssetsRoute.kt`、`CheckedSshNativeClient.kt` | 已对齐 | Android | 指纹可复制；变更、撤销和未知密钥均无绕过路径。 |
| 外部链接 | `ssh://` / `orbitterm://connect` 只预填充服务器审核页，不携带凭据且不自动连接 | `DeepLinkManager.swift`、`ContentView.swift` | `DeepLinkCoordinator.kt`、`AssetsViewModel.kt`、`MainActivity.kt` | 已对齐 | Apple + Android | 拒绝密码、令牌、私钥、控制字符与超长字段；未解锁或审核页未就绪时保留待处理链接；现有与新资产都必须经用户明确保存并连接。 |
| 连接与同步状态 | 用户可见主状态使用固定词典，详细原因不替代连接事实 | `ConnectionPresentation.swift`、`OperationRecoveryPresentation.swift` | `ConnectionPhasePresentation.kt`、`TerminalSessionStatus.kt`、`SyncStatusPresentation.kt` | 已对齐 | Apple + Android | 连接主状态固定为“连接中 / 重连中 / 已连接 / 已断开 / 连接失败”；同步主状态固定为“等待网络 / 等待解锁 / 同步中 / 同步失败”；无可靠会话证据不得显示“已连接”或“在线”。 |
| 连接 | Telnet 仅能在明确风险确认后创建、测试和连接 | `SessionManager.swift`、`TelnetRiskConfirmationView.swift` | `AndroidTransportSupportPolicy.kt`、`AssetsRoute.kt`、`TelnetTerminalConnection.kt` | 已对齐 | Apple + Android | 两端均需显式风险确认；Telnet 禁用跳板、Host Key、SFTP、Docker 与监控；SSH 失败绝不自动降级。 |
| 会话 | 多 SSH 会话选择、关闭、重连和迟到回调隔离 | `Core/SessionManager.swift` | `feature/terminal/TerminalSessionController.kt`、`OperationScopeCoordinator.kt` | 已对齐 | Android | 锁定、登出、切换账号或关闭会话后，迟到回调不能复活旧 UI 或 handle。 |
| 会话 | 网络切换、进程重建与显式恢复契约 | `ApplicationNetworkAvailability`、`SessionManager.handleConnectionLost`、`LiveSessionRecoveryMarker` | `NetworkAvailabilityObserver.kt`、`TerminalReconnectPolicy.kt`、`LiveSessionRecoveryPreferences.kt` | 已对齐 | Apple + Android | 局域网 SSH 不依赖公网验证；无可用网络时重连入口不可用并有文本/无障碍提示；网络恢复只恢复手动重连能力，不自动绕过凭据或 Host Key；进程重建后不伪造原生 handle，只以不含账户、主机或输出的单比特标记提示旧会话未恢复；连接丢失先撤销租约和 UI 通道所有权，再完成有序清理，旧回调不得覆盖新连接。 |
| 会话 | 在没有活动会话时仍能离开会话页 | `MainWorkstationView.swift` | `MainScreen.kt` 的 `shouldShowBottomDock` | 已对齐 | Android | 无会话显示底部导航；有活动终端时隐藏导航以保留可视高度。 |
| 终端 | 输入、ANSI 输出、滚动历史、回到底部、清屏、复制/粘贴与快捷键 | `SwiftTermTerminalView.swift`、`WorkstationTerminalSessionPane.swift` | `RemoteTerminalCanvasView.kt`、`TerminalClipboard.kt`、`TerminalSessionsRoute.kt` | 已对齐 | Android | 大输出无 ANR；复制/粘贴须由显式用户操作触发，敏感剪贴板按策略清理。 |
| 隐私 | 剪贴板按内容类型分级，避免密码、私钥和终端输出无限期暴露 | `SecureClipboard.swift`、`ClipboardSecurityPolicyTests.swift` | `SensitiveClipboard.kt`、`ClipboardContentKindPolicyTest.kt` | 已对齐 | Apple + Android | 凭据和私钥不得写入剪贴板；终端内容和主机指纹 60 秒后仅在仍为本次内容时清除，并使用系统支持的本机/敏感标记；公钥、容器 ID 和脱敏诊断可普通复制。 |
| 隐私 | 任务切换、录屏和截图时保护解锁后画面与短期敏感输入 | `SensitiveScreenProtection.swift`、`ClipboardSecurityPolicyTests.swift` | `MainActivity.kt` 的 `FLAG_SECURE` | 有意差异 | Apple + Android | Android 由 `FLAG_SECURE` 阻止截图、录屏与任务预览；iOS 在录屏或非活跃场景覆盖内容，系统截图无法阻止时立即清理短期敏感输入；均不得在锁定后暴露已解密内容。 |
| 终端 | 移动端键盘附件的常用键、方向键与符号集合一致 | `SwiftTermPlatformSupport.swift`、`MobileSessionViews.swift` | `TerminalSessionsRoute.kt`、`TerminalSpecialKeyOrderTest.kt` | 已对齐 | Apple + Android | 键盘附件使用策划固定顺序；“快捷操作”可按本机使用频率排序，仅保存标签与计数，不保存命令或输出。 |
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
| 监控 | 绑定当前会话，六项摘要、六张趋势图、进程、刷新/暂停与错误态 | `MobileSessionComponents.swift`、`MonitorService.swift` | `MonitorPanel.kt`、`CheckedMonitorNativeClient.kt` | 已对齐 | Apple + Android | 摘要固定为 CPU、内存、磁盘、TCP 延迟+失败率、下载、上传；切换会话后旧采样不可显示。 |
| 监控 / SFTP / Docker | 加载、空数据、暂停、失败与就绪状态使用稳定主标题；刷新、重试、旧数据保留、忙碌反馈和结果提示遵循统一操作契约 | `OperationRecoveryPresentation.swift`、`AppThemeComponents.swift`、`MobileSessionComponents.swift`、`SFTPBrowserView.swift`、`DockerManagerView.swift` | `OperationalContentPresentation.kt`、`OperationalFeedbackComponents.kt`、`MonitorPanel.kt`、`SftpRoute.kt`、`DockerRoute.kt` | 已对齐 | Apple + Android | 同一状态在两端显示相同主标题；失败后刷新入口改为“重试”；刷新中禁用重复提交并显示进度；旧数据继续显示时必须明确说明；监控统一使用“暂停采样 / 恢复采样”；成功结果显示 4 秒后自动消失，失败及部分失败结果保持到重试或下一次操作。 |
| 监控 | 客户端到当前资产 SSH 端口的 TCP 延迟与近 20 次样本丢包率 | `MonitorService.swift`、`MobileSessionComponents.swift` | `TcpLatencyProbe.kt`、`MonitorPanel.kt` | 已对齐 | Apple + Android | 目标必须是当前资产主机和实际 SSH 端口；连接失败记入丢包而不伪造延迟。 |
| 监控 | 最短采样间隔 | iOS 可选 1/2/5 秒 | Android 可选 2/5 秒 | 有意差异 | Android | Android 维持 2 秒下限以满足前台会话、电量及 100ms 帧基线；后续需在真机功耗证据支持后才可开放 1 秒。 |
| 监控 | 移动趋势窗口固定为最近 5 分钟，不显示无效选择 | iOS 移动设置不再显示工作站范围选择；macOS 仍支持实时/5/10 分钟 | Android 六张移动趋势图固定 5 分钟 | 已对齐 | Apple + Android | 移动端不得出现选择后不改变图表的假配置；macOS 工作站的真实筛选属于桌面能力。 |
| 发布边界 | 内部后端切换入口不得出现在公开移动 Release | Apple Debug 保留经二次确认的开发入口，`ORBITTERM_PUBLIC_RELEASE` 编译为空操作 | Android 产品界面无后端切换入口 | 已对齐 | Apple | Release 门禁检查条件编译结构并扫描产品二进制；不得仅靠隐藏手势保护内部入口。 |
| 同步 | 资产、跳板与命令片段加密同步；账户隔离、等待状态、部分失败和冲突选择 | `SyncPresentationState`、`SyncService+Synchronization.swift`、`SyncService+Conflict.swift` | `SyncStatusPresentation.kt`、`SyncRepository.kt`、`ApplicationSyncCoordinator.kt` | 已对齐 | Apple + Android | 等待网络、等待解锁、同步中、同步失败使用固定标题；延后项目或待处理冲突不得标成同步完成；冲突统一显示“检测到同步冲突”及“保留本地修改 / 保留云端修改”；跨账户、锁定、登出期间的旧任务不写入新作用域。 |
| 同步传输 | HTTP 状态码、传输中断与 `Retry-After` 使用同一白名单恢复契约 | `SyncHTTPResponsePolicy.swift`、`NetworkService.swift`、`RetryClockGuard`、`NetworkServiceFaultInjectionTests` | `SyncHttpResponsePolicy.kt`、`RetryClockGuard.kt`、`OrbitApi.kt`、`OrbitApiFaultInjectionTest`、`SyncWork.kt`、Room v11 | 已对齐 | Apple + Android | 401 等待重新认证；408、425、429 与 5xx 有界重试；其他 4xx 立即隔离；有效秒数或 HTTP-date 延迟最多采纳 3600 秒且不得缩短本地退避。超时和短暂断线可按平台原生网络栈有界重试，取消绝不重试且必须同步清除“正在重试”状态；200 非法 JSON/结构损坏稳定归为协议异常并隔离。自动重试和等价重放保持同一幂等请求头。持久截止时间负责跨启动恢复，当前进程同时使用系统单调时间抵御用户前跳或回拨系统时间。新账户解锁会原子撤销旧账户投递租约。Android 另以关闭并重开 Room 验证延迟跨解锁、进程等价重启和账户切换持久保留。故障夹具不访问外网且不得进入 Release。 |
| 同步与迁移 | 冷启动、进程重建、账户切换和旧数据迁移均保持原账户所有权 | `ServerStore.swift`、`SyncQueue.swift`、`OperationOwner` | `SyncWork.kt`、`OrbitTermMigrations.kt`、`OrbitTermDatabaseMigrationTest.kt` | 已对齐 | Apple + Android | 持久同步意图可以保留，但新进程必须等待本次主密码解锁后取得新租约；旧进程、旧解锁轮次及旧账户任务不能发布状态或消费当前队列；迁移不得猜测无归属数据的账户，不得使用破坏性回退，持久化失败时保留原恢复源供下次重试。 |
| 同步重放 | 服务端已提交但响应丢失时，重放必须保持同一请求身份且不得覆盖更新后的本地意图 | `SyncRequestIdentity.swift`、`SyncQueue.swift` | `SyncRequestIdentity`、`AssetSyncOutboxEntity`、`OrbitTermMigrations.V8_TO_V9` | 已对齐 | Apple + Android | 上传及删除/恢复/永久删除附带不含明文的稳定幂等键；Android 状态变更的 `operation_id` 随 Room 意图持久化，前台失败转后台也必须沿用；迟到响应只能删除身份相同的队列项。云端已回显完整相同资产时视为原上传完成，凭据只在内存中比较，不保存秘密摘要。 |
| 同步诊断 | 未知结果入队、投递延后、冲突、幂等回显和迟到响应均使用白名单聚合计数 | `DiagnosticsManager`、`SyncDiagnosticEvent` | `PrivacySafeSyncMetrics`、诊断信息导出 | 已对齐 | Apple + Android | 只保留事件类别和进程内次数，不记录时间线关联、账户、资产、请求键、服务地址、异常正文或密文；退出和切换账户必须清空，锁定同一账户不清空以便本次支持诊断。 |
| 本地存储恢复 | Keychain/Keystore、SQLite/Room 暂时不可用、损坏、空间不足或迁移提交失败时暂停并原地重试 | `AppSession.swift`、`SyncQueue.swift`、`LocalStorageRecoveryPolicy` | `LocalStorageRecovery.kt`、`SecureCredentialStore.kt`、`LocalStorageRecoveryScreen.kt` | 已对齐 | Apple + Android | 存储故障不得伪装为退出登录、错误主密码或空数据；不得自动清库、覆盖凭据或绕过持久队列；恢复操作只重新验证并打开原存储。 |
| 高压力与资源边界 | 终端输出、SFTP、Docker 日志、监控历史和持久同步积压均使用有界内存、有限并发与可续跑切片 | `OperationResourceBudget.swift`、`TerminalChunkBuffer.swift`、`SyncQueue.swift` | `RuntimeResourceBudget.kt`、`NativeTerminalOutputRouter.kt`、`SftpRoute.kt`、`SyncWork.kt` | 已对齐 | Apple + Android | 持久同步任务不因资源上限而删除；Android 每段最多读取 100 条 outbox 后以同一解锁租约续接，Apple 每投递 100 条主动让出队列所有权；进程重建、断网、锁定、退出或换账户后旧切片不得启动或发布状态；真实 SFTP 大文件与功耗仍保留到真机验收。 |
| 同步 | 资产页显式“立即双向同步” | `ServerListView.swift` | `AssetsRoute.kt` | 已对齐 | Apple + Android | 按钮只由用户触发；锁定或未登录时不绕过主密码，同步中有可访问的进度状态。 |
| 同步 | 独立 SSH 密钥库与保存的端口映射配置 | Keychain E2EE 合并、墓碑、账户隔离与移动端管理入口 | Keystore E2EE 合并、墓碑、账户隔离与移动端管理入口 | 已对齐 | Apple + Android | 本机专用密钥和正在运行的隧道状态不进入云端；包含 tunnel/process/running/auto-start 字段的映射信封继续拒绝；移动端只在前台且有已验证 SSH 会话时启动本地映射。 |
| 运维工具 | 移动端密钥管理、端口映射与批量命令均有可发现入口 | `MobileMoreView`、`MobileSSHKeyManagementView`、`MobilePortForwardingView`、`BatchCommandRunnerView` | `MainScreen.kt`、`SecurityToolsDialog.kt`、`AssetsRoute.kt` | 已对齐 | Apple + Android | 批量命令只对用户明确选定的 SSH 资产执行；未验证会话安全连接或显式失败。 |
| 同步 | 网络恢复后的可靠续跑 | iOS `SyncQueue` | Android `WorkManager` 与 `SyncWork.kt` | 有意差异 | Android | Android 后台任务不持有明文主密码；账户切换、锁定和登出取消旧作用域任务。 |
| 会话后台 | 普通退后台立即锁定并清除内存密钥；系统文件选择使用受控短时例外 | iOS 进入后台立即锁定 | Android 普通后台立即锁定；文件选择期间使用 Android 前台服务与常驻通知并设 2 分钟上限 | 有意差异 | Apple + Android | 旋转不误锁；普通 Home/切应用立即关闭活动会话并回到解锁页；Android 仅在用户主动打开 SAF 文件选择器时延后，2 分钟到期必须锁定，返回后不得误触发多次生物识别。 |
| 会话后台 | Android 前台服务通知按锁屏可见性脱敏 | iOS 无对等持续会话通知 | `ActiveSessionService.kt`、`ActiveSessionNotificationPresentationTest.kt` | 有意差异 | Android | 解锁后通知只显示有界会话数；锁屏公开版本不显示数量、账户、主机、用户名、路径、命令、输出或凭据；通知点击只返回应用。 |
| 账户与诊断 | 主题、终端主题、诊断、帮助与反馈 | `SettingsView.swift`、`DiagnosticsExportView.swift` | `MainScreen.kt`、`OrbitTheme.kt`、`OrbitDesign.kt`、`OrbitDesignScreenshotBaselineTest.kt` | 已对齐 | Android | 应用主题不改变 ANSI 主题；诊断默认脱敏，不包含账户、主机、命令、路径、私钥或令牌；危险操作与固定视觉状态受语义/截图回归覆盖。 |
| 账户与诊断 | 移动端条款、隐私边界和邮件反馈入口 | `MobileSessionViews.swift` | `MainScreen.kt`、`AdministratorContactRepository` | 已对齐 | Apple + Android | 明确合法授权责任和诊断脱敏范围；Android 联系邮箱保留可由服务端刷新接口，离线使用安全默认值。 |
| 无障碍 | 安全状态不只依赖颜色；关键反馈有文本与语义 | iOS `AppAccessibilityPresentation.swift` | `OrbitDesign.kt`、`RemoteTerminalCanvasView.kt`、`TerminalSessionsRoute.kt`、`OrbitEmptyStateComposeTest.kt`、`P2AccessibilityLayoutRegressionTest.kt` | 待完成 | Android | 自动化验证标题/动态反馈语义、字体 200% 危险操作可达性、横屏布局与硬件键映射；仍须以 TalkBack、分屏和真实硬件键盘完成设备回归。 |

## 发布阻断与后续顺序

1. **P2 必做**：完成 TalkBack / VoiceOver / 大字体 / 横屏验证；Telnet 以两端相同的明文风险契约验收。
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
