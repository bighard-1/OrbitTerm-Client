# OrbitTerm iOS / Android 移动端全量差异审计

审计日期：2026-08-30
审计范围：当前仓库中 iOS 与 Android 移动端的认证、主密码、导航、服务器、连接、终端、快捷操作、Snippets、监控、SFTP、Docker、个人中心、同步、安全、无障碍和系统生命周期。
判定标准：同一品牌的页面结构、功能命名、状态语义和操作结果必须一致；系统安全容器、文件选择器、输入法和后台机制使用各平台原生实现，不追求控件源码或像素级复制。

## 总结

- 两端的五个主入口、主要运维能力、凭据安全边界和危险操作契约已经基本一致。
- 本轮发现的品牌感知风险主要不在“缺少大功能”，而在可点击状态、标签集合、删除后果文案、指标数量和导航容器等细节。
- 本轮已直接处理 P0/P1 差异；不应对齐的项目均保留平台原生方式，并在下文给出理由。

## 一、已直接完成的对齐

| ID | 模块 | 审计时发现的差异 | 原生对齐判定 | 本轮结果 | 自动验收 |
| --- | --- | --- | --- | --- | --- |
| A01 | 服务器卡片 | 两端都要求 3 秒内点两次才连接，第一次点击看似失效 | 可；单击主操作更符合 iOS 与 Android 触摸习惯 | 两端均改为单击连接，编辑保留独立按钮/菜单 | 静态门禁拒绝 `armedConnection` 和“点击两次”回归 |
| A02 | 空服务器页 | iOS 使用“服务器”，Android 使用“资产” | 可 | Android 主空态改为“还没有服务器” | Android 编译 |
| A03 | 删除语义 | 两端普通删除均说“永久/不可撤销”，但产品实际提供最近删除恢复 | 可，且必须修正误导 | 两端均明确“移入最近删除+移除本机凭据+保留期内可恢复”；仅最近删除内的清理仍为不可撤销 | 两端构建+对齐门禁 |
| A04 | Android 底部导航 | Android 外层为带边距的悬浮圆角容器，iOS 为全宽系统 Tab Bar | 可；两端仍使用各自系统导航控件 | Android 改为全宽 Material 3 `NavigationBar`，保留 Material 选中指示 | Compose 编译 |
| A05 | 注册按钮 | iOS 按照邮箱、邀请码和 12 位组合密码实时禁用；Android UI 只检查非空，点击后才被 ViewModel 拒绝 | 可 | Android UI 与 ViewModel 共用同一校验规则 | `AuthValidationTest`+应用单测 |
| A06 | 账号规范化 | Android 登录使用小写邮箱，注册保留原大小写；iOS 两条路径均规范化 | 可 | Android 注册也使用 `trim().lowercase()` | `AuthValidationTest`+编译 |
| A07 | 登录冷却 | Android ViewModel 有冷却，页面却仍表现为可点；iOS 显示倒计时并禁用 | 可 | Android 传入剩余秒数，显示安全提示并禁用提交 | Compose 编译+单测 |
| A08 | 会话模块名称 | 历史文档与部分旧 UI 在“快捷指令/命令片段”之间混用 | 可 | 当前两端固定为“终端 / 快捷操作 / 监控 / Snippets” | 静态门禁同时检查两端四个标签 |
| A09 | 键盘附件 | iOS 与 Android 的方向键、运算符、管道、反斜线等集合不同；Android 使用频率会改变键盘顺序 | 可 | 内置“常用/符号”集合与顺序完全统一；键盘附件不再动态重排 | `TerminalSpecialKeyOrderTest`+静态门禁 |
| A10 | 快捷操作符号 | iOS 页面内符号子集与自身键盘附件也不一致 | 可 | iOS 页面内符号改用同一策划集合；“×”显示仍发送 `*` | iOS 构建 |
| A11 | 监控摘要 | iOS 为 6 项，Android 把 TCP 失败率拆成第 7 张卡 | 可 | Android 合并为“TCP 延迟 · 失败率”，两端均为 6 项 | Android 单测+静态门禁 |
| A12 | 监控顶部操作 | Android 有页内刷新、暂停/开始，iOS 只显示状态 | 可 | iOS 补齐“系统监控”标题、刷新和暂停/开始，直接复用既有已验证会话 | iOS 构建 |
| A13 | 监控摘要布局 | iOS 用普通 `HStack`，窄屏可压缩；Android 可横向滚动 | 可 | iOS 改为横向 `ScrollView`，两端均保留 92 的最小指标宽度 | iOS 构建 |
| A14 | 延迟趋势详情 | Android 显示 P50/P95/失败率，iOS 只显示当前值 | 可 | iOS 补齐近 20 次的 P50/P95/失败率 | iOS 构建 |
| A15 | 关于页 | Android 版本号写死，iOS 移动页不显示安装版本 | 可 | 两端均从安装包元数据读取实际版本，iOS 额外显示构建号 | 两端构建 |
| A16 | Telnet 文档 | 文档称 Android 只能同步保存，实际代码已支持创建、测试、连接、重连和风险确认 | 可，必须以代码为真实源 | 对齐矩阵改为“已对齐”，明确两端都不会从 SSH 自动降级 | 静态门禁要求 `TelnetTerminalConnection.kt` 证据 |
| A17 | 连接与同步状态词典 | iOS 会话标题展示自由文本，Android 固定写“终端在线”；同步标题也存在“正在/需要处理”等同义表达 | 可，且必须由类型化状态驱动 | 两端统一为“连接中 / 重连中 / 已连接 / 已断开 / 连接失败”和“等待网络 / 等待解锁 / 同步中 / 同步失败”；详细原因与主状态分离，Apple 只有在租约、终端通道和可用状态同时成立时才显示“已连接”；Android 在原生会话明确关闭后显示“已断开”；Apple 辅助配置部分失败不得显示“同步完成” | Apple `ConnectionPresentationTests`；Android `ConnectionPhasePresentationTest`、`TerminalSessionStatusTest`、`SyncStatusPresentationTest`；静态门禁拒绝会话标题回归“终端在线” |
| A18 | 移动监控范围 | iOS 移动设置提供实时/5/10 分钟选择，但移动会话图固定显示 5 分钟；Android 没有该假选项 | 可 | iOS 移动设置移除无效范围选择，与 Android 固定 5 分钟一致；macOS 工作站真实可变范围保留 | iOS/macOS 条件编译构建；发布门禁检查存储字段仅属于 macOS |
| A19 | 开发后端入口 | Apple 隐藏点击入口会编入公开 Release，Android 无产品入口 | 可，且应按发布安全边界处理 | Apple 将入口、确认状态和文案整体收进非公开编译分支；Debug 保留原生安全确认，公开 Release 使用无操作修饰器 | Debug/Release 分别构建；Release 源码与二进制夹具排除门禁 |

## 二、当前已经一致、不应重复改造的细节

| ID | 模块 | 一致性结论 | 代码证据/验收重点 |
| --- | --- | --- | --- |
| B01 | 根导航 | 两端均为服务器、会话、SFTP、Docker、个人中心五入口 | `ContentView.swift`、`MainScreen.kt` |
| B02 | 会话全屏 | 活动终端时隐藏底栏，无会话时恢复导航，避免死路 | `MobileSessionViews.swift`、`shouldShowBottomDock` |
| B03 | 认证结构 | 登录/注册切换、邮箱、密码、邀请码、条款同意和错误反馈的顺序一致 | `AuthView.swift`、`LoginScreen.kt` |
| B04 | 主密码 | 首次设置、验证、生物识别解锁、失败不建立信任、普通退后台锁定契约一致；生物识别注册失效后均 fail-closed，必须用主密码恢复并显式重新启用 | `BiometricAuthService.swift`、`MasterPasswordGateView.swift`、`MasterPasswordScreen.kt`、`MasterPasswordViewModel.kt`、`AppLockLifecyclePolicy.kt` |
| B05 | 服务器编辑器 | 标识元数据→地址/传输→认证→SSH 路由的顺序一致；Telnet 强制密码并禁用跳板 | `AddServerView.swift`、`AssetsRoute.kt` |
| B06 | Host Key | 首次明确信任；changed/revoked/unsupported 阻断；取消不建立会话 | `HostKeyTrustViews.swift`、`CheckedSshNativeClient.kt` |
| B07 | 跳板机 | 跳板与目标分别验证凭据和主机密钥，最终会话被终端/SFTP/Docker/监控复用 | `JumpHostConfigurationSection.swift`、`AssetsViewModel.kt`、checked SSH v2 |
| B08 | 批量导入 | 引号逗号、Tab/分号、重复端点、逐行错误隔离和容量上限语义一致 | `AssetBulkAddSheet.swift`、`AssetBulkImportParser.kt` |
| B09 | 终端核心 | 输入、ANSI 输出、滚动历史、返回最新、重连、关闭、多会话切换的结果一致 | `SwiftTermTerminalView.swift`、`RemoteTerminalCanvasView.kt`、`TerminalSessionController.kt` |
| B10 | Snippets | 分类、搜索、变量、资产范围、插入/执行、历史保存和加密同步结果一致 | `SnippetsPanelView.swift`、`TerminalSessionsRoute.kt` |
| B11 | SFTP 路径 | 路径直达、面包屑、目录浏览和当前已验证会话门控一致 | `SFTPBrowserView.swift`、`SftpRoute.kt` |
| B12 | SFTP 文本 | UTF-8 预览/编辑、2 MB 上限、未保存离开确认、远端快照冲突保留草稿一致 | `SFTPBrowserEditState.swift`、`SftpInAppDocumentPolicy.kt` |
| B13 | SFTP 文件操作 | 新建、重命名、chmod、删除、递归删除、多选、ZIP、上传/下载、FIFO、取消/重试结果一致 | `SFTPManager+FileOperations.swift`、`SftpRoute.kt` |
| B14 | Docker 能力 | 列表、状态、日志、启动、停止、重启、暂停、恢复、强制停止、删除的可用性与危险确认一致 | `DockerManagerView.swift`、`DockerRoute.kt` |
| B15 | 监控图表 | CPU、内存、磁盘、TCP 延迟、下载、上传六张趋势图与进程监控均存在 | `MobileSessionComponents.swift`、`MonitorPanel.kt` |
| B16 | 个人中心分组 | 账户与安全→设置与偏好→运维工具→帮助与信息→当前会话的顺序一致 | `MobileMoreView`、`MoreScreen` |
| B17 | 主题 | 浅/深/跟随系统、五套品牌配色、终端 ANSI 主题与字号范围一致 | `AppThemeManager.swift`、`OrbitTheme.kt` |
| B18 | 同步 | 资产、跳板、SSH 密钥、端口映射和 Snippets 均使用账户隔离的 E2EE 语义；运行态不同步 | `SyncService`、`ApplicationSyncCoordinator` |
| B19 | RDP 移动端 | iOS 与 Android 当前都只保存/同步 RDP 资产，不把 RDP 伪装成 SSH；当前 FreeRDP 图形工作区为 macOS 能力 | `SessionManager.swift`、Android “RDP · 仅同步” |
| B20 | 剪贴板分级 | 两端均禁止凭据和私钥进入剪贴板；终端内容与主机指纹使用 60 秒条件清除，用户后续复制的其他内容不会被误清理 | `SecureClipboard.swift`、`SensitiveClipboard.kt` |
| B21 | 敏感画面 | 两端在离开活跃场景或锁定后不向任务预览暴露解密内容；Android 用 `FLAG_SECURE`，iOS 用覆盖层、录屏检测与截图后短期输入清理 | `SensitiveScreenProtection.swift`、`MainActivity.kt` |
| B22 | 外部连接审核 | 两端均只把无凭据的 `ssh://` / `orbitterm://connect` 解析为服务器审核草稿；现有资产也不会自动连接，未解锁或审核未就绪时保留待处理请求 | `DeepLinkManager.swift`、`DeepLinkCoordinator.kt`、`ContentView.swift`、`AssetsViewModel.kt` |

## 三、必须保留的原生差异（不建议强行一致）

| ID | 差异 | 不能/不应生搬硬套的理由 | 必须对齐的外部契约 |
| --- | --- | --- | --- |
| N01 | SwiftUI/UIKit 与 Jetpack Compose/Android View | 控件树、焦点、语义树和生命周期不同；共享 UI 实现会损害原生交互和可维护性 | 页面层级、标签、状态、主次操作和可访问名称一致 |
| N02 | Keychain/Secure Enclave 与 Android Keystore | 系统安全 API、返回码和硬件能力不同 | 凭据不进普通存储、账户隔离、锁定/登出清内存、失败不降级 |
| N03 | LocalAuthentication 与 BiometricPrompt | Face ID/Touch ID 与 Android 指纹/人脸的强度分级、文案和取消行为由系统管理 | 只用于解锁，不代替主密码建立信任，失败不进入主页 |
| N04 | SwiftTerm 与 Android 原生终端画布 | 底层字形、IME、文本选择、硬件键盘派发和无障碍实现不同 | ANSI 颜色、字号、宽字符、滚动、复制粘贴安全和快捷键结果一致 |
| N05 | iOS Files/分享表与 Android SAF/FileProvider | Android 的 URI 权限与 iOS 安全范围 URL 机制不同；不应绕过系统文件容器 | 用户选择目标、进度、取消、失败恢复、临时分享权限和文件内容一致 |
| N06 | iOS 后台限制与 Android 前台服务 | iOS 不允许任意持续 SSH；Android 长会话必须显示常驻通知 | 前台在线状态必须真实，锁定/登出不得留存可用凭据；Android 通知锁屏公开版本不显示会话数或远端标识 |
| N07 | iOS 手势/上下文菜单与 Android 溢出菜单/系统返回 | 各平台用户对返回、长按、滑动操作的预期不同 | 功能必须可发现，主操作位置和危险确认结果一致 |
| N08 | iOS `TabView` 与 Material 3 `NavigationBar` | 字形、选中背景和系统安全区由平台决定 | 全宽底部层级、五个入口顺序、名称和隐藏时机一致 |
| N09 | 监控最短周期：iOS 1/2/5 秒，Android 2/5 秒 | Android 已建立前台会话、电量和帧时间基线；无真机功耗证据前开放 1 秒会放大风险 | 默认值、用户可见单位、暂停/恢复和数据窗口语义一致 |
| N10 | 个人中心展开方式 | iOS 用 `NavigationLink` 进入子页，Android 用可折叠 Material Card；两者都是原生层级表达 | 五组顺序、卡片标题/摘要、子项可达性和危险操作层级一致 |
| N11 | Docker 操作入口 | iOS 使用原生上下文菜单/详情，Android 在卡片上显示 Material 操作；该差异已有明确产品决定保留 | 可用操作集合、二次确认、加载/失败/无数据状态一致 |
| N12 | 无障碍服务 | VoiceOver 和 TalkBack 的焦点顺序、手势与朗读节奏由系统决定 | 标题、状态、危险等级、按钮名称、大字号可达性和不泄露终端内容的原则一致 |

## 四、仍存在但不应在本轮冒险强行改造的差异

| ID | 差异 | 是否最终可对齐 | 本轮不直接实施的理由 | 后续可执行计划与验收 |
| --- | --- | --- | --- | --- |
| P01 | Android 支持账户隔离的自定义终端键，iOS 只有策划内置键 | 可 | 直接删除 Android 会破坏已有用户配置；仓库尚无跨端自定义键信封、转义语法版本和冲突合并契约，只在 iOS 做本机副本会再次造成同步差异 | P2：先定义 `terminal_custom_keys` E2EE v1（标签、字节语法、分区、墓碑、上限），再补 iOS 原生编辑器；往返同步、非法转义和账户切换为发布门禁 |
| P02 | Android 支持服务端刷新管理员邮箱，iOS 邮件入口使用固定地址 | 可 | 把 Android 退化为固定地址会丢失远程维护能力；iOS 尚无对应 API/缓存仓库，不应临时在 View 中发网络请求 | P2：将联系配置纳入共享 API 契约，iOS 增加带离线默认值的 repository；两端验证无邮件应用错误态 |
| P04 | Android Docker 日志使用大尺寸 `AlertDialog`，iOS 使用导航式日志页 | 可 | 用户已明确允许 Docker 页面差异保持现状；本轮不应逆转既有产品决定 | 若产品决定变更：Android 改为全屏 Material 对话/导航目的地，验收长日志滚动、自动刷新、返回和会话切换 |

## 五、分阶段后续计划（不含真机项）

### P0：防止现有对齐回归

1. 对齐矩阵每次修改必须同时核对源码，不得把实现已有的功能记为不支持。
2. 静态门禁固定检查：五个主入口、四个会话模块、六项监控、单击连接、Telnet 独立风险契约。
3. Android 持续执行 feature/app 单测与 Debug/Release 构建；iOS 持续执行 Simulator Debug 构建与 Checked FFI 测试。

### P1：细节契约继续收敛

1. 将所有用户可见的“资产/服务器”文案按场景收敛：导航和空态用“服务器”，批量、同步和安全语义可用“资产”。
2. 为 Android 登录冷却、删除恢复文案和六项监控新增 Compose 语义测试；为 iOS 监控刷新/暂停和关于页新增 XCUITest 根状态断言。
3. 已完成连接与同步主状态词典；下一轮继续将监控、SFTP、Docker 的“加载 / 空 / 暂停 / 失败”状态纳入同一展示契约。

### P2：需要共享契约后才可实施

1. 自定义终端键 E2EE v1：先定义便携数据模型和冲突规则，再增加 iOS UI，禁止以删除 Android 功能方式“对齐”。
2. 管理员联系配置：共享 API、缓存、离线默认值和安全 URL 校验。
3. 监控窗口策略已确定为移动端固定 5 分钟；iOS 无效选择已移除，macOS 工作站继续提供真实范围选择。

## 六、本轮验收记录

- Android 全模块 `testDebugUnitTest`、`:app:assembleDebug`、`:app:assembleRelease`：通过；135 项 JVM 测试，0 失败。
- Android `:app:lintDebug`：通过，0 errors、31 warnings；自检清理了登录/个人中心中 5 条旧式 API 提示，剩余项为依赖升级、屏幕方向策略和第三方原生库 16 KB 对齐等非本轮阻断项。
- Android `:app:assembleRelease`（R8 压缩/混淆与资源压缩）：通过。`liborbit_core.so` 由于工具无法再次剝离符号而按原样打包，不是构建错误。
- iOS `OrbitTerm_iOS` / iOS Simulator / Debug 与 macOS Debug / 禁用签名构建：通过。
- Apple `OrbitTermCheckedFFITests`：268 项通过，0 失败；iOS 功能/无障碍 UI 回归 10 项通过。
- Android arm64 Debug 包已安装至 API 36 ARM64 模拟器并打开登录页；`FLAG_SECURE` 会让自动截屏内容区呈黑色，无障碍树已核对品牌标题、登录/注册、账号、密码和协议入口完整存在。
- Android 测试首轮发现旧快捷键集合断言，已修正后重跑通过。
- 真机项不在本次验收范围，不用模拟器或编译结果替代真机证据。
