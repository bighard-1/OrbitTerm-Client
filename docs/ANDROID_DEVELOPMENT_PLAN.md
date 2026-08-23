# OrbitTerm Android 原生客户端开发方案

## 1. 目标与边界

Android 端定位为原生运维客户端：在功能、安全语义和数据模型上与 iOS/macOS 保持一致；在导航、返回、键盘、权限和后台运行上遵循 Android 的系统习惯。

首个正式版本必须具备：账号与本地解锁、资产管理、经过 Host Key 验证的 SSH 终端、密钥与密码认证、会话管理、SFTP、配置同步、诊断导出和必要的设置。Monitor、Docker 与 Batch 在核心终端稳定后分阶段交付。

以下能力不纳入首发承诺：端口转发（所有平台尚无已实现契约）、Docker rename/update、Quick Key 远程部署、已变更 Host Key 的继续信任、未验证会话上的 Batch。

## 2. 现状与关键决策

| 项目 | 当前现状 | 决策 |
| --- | --- | --- |
| UI | Kotlin + Compose + Material 3，只有静态 demo 资产页 | 保持 Compose 原生开发，不移植 SwiftUI 页面布局 |
| 安全核心 | Rust `orbit-core` 已有 checked SSH、terminal、SFTP、Monitor、Docker 与 Host Key 验证 | Android 必须调用同一 checked API；不得另用“接受所有 Host Key”的 SSH 实现 |
| Android bridge | 仅有 portable sync 的手写 JNI | 新的长生命周期/复杂接口以 UniFFI 生成 Kotlin binding 为主；保留极小的 JNI 壳用于加载库或兼容同步接口 |
| 存储 | 已有 EncryptedSharedPreferences 骨架 | Room 保存非敏感配置、队列和 shadow；Android Keystore 加密保存敏感凭据与主密钥材料 |
| ABI | 当前只配置 `arm64-v8a` | Alpha 先维持 arm64；发布前补 `armeabi-v7a` 和 `x86_64`（模拟器），并在 CI 验证 |

## 3. 产品范围与信息架构

底部主导航采用四项：**资产**、**会话**、**工具**、**设置**。窄屏每次聚焦一个主要任务；平板、横屏和 ChromeOS 使用 NavigationRail + 双栏或三栏自适应布局。

| 区域 | 首发功能 | Android 适配 |
| --- | --- | --- |
| 资产 | 搜索、分组/标签、添加/编辑、复制、删除/恢复、连接测试 | Floating Action Button 新增；长按打开上下文菜单；列表使用 Paging/惰性加载 |
| 会话 | 多会话列表、连接/断开、终端、重连、状态与诊断 | 顶部标签或会话切换器；所有 Android 移动设备保持单终端视图，不提供终端分屏入口 |
| 工具 | SFTP；后续 Monitor、Docker、Batch、Snippet | 仅展示当前 verified session 可使用的工具；不可用原因必须明确 |
| 设置 | 账户、安全、终端外观、连接、同步、诊断 | 使用 Material 偏好页面模式；危险项进入确认页，不用简单 switch 绕过确认 |

视觉上复用 OrbitTerm 的品牌、术语、图标含义、终端主题和安全颜色语义；不强制复制 iOS 的控件形态。应用主题与终端 ANSI 主题完全分离，切换应用主题不得改变终端配色。

## 4. 推荐工程结构

```text
clients/android/OrbitTermAndroid/app/src/main/java/com/orbitterm/android/
  app/                  # Activity、App、导航、窗口与前台服务入口
  core/                 # UniFFI/JNI、错误映射、dispatcher、日志抽象
  data/
    local/              # Room、DataStore、Keystore credential store
    remote/             # Ktor API、同步 DTO
    repository/         # Asset、session、sync、settings repository
  domain/               # 用例、不可变模型、状态机和策略
  feature/
    auth/ assets/ terminal/ sftp/ monitor/ docker/ settings/ diagnostics/
  design/               # Material theme、semantic tokens、通用组件
```

- 每个 feature 采用 `screen / viewmodel / ui-state / event`；UI 只渲染不可变 `StateFlow`，不直接调用 FFI、Room 或网络。
- ViewModel 使用 `viewModelScope`；连接和传输使用有明确 owner 的 application/session scope，断开时可取消。
- Navigation 只传递 ID 和轻量参数，不传密码、私钥、terminal buffer 或 native handle。
- 依赖注入选用 Hilt；首个 PR 同时建立 test fake 与模块边界，避免之后将 SessionManager 变成全局单例。

## 5. 核心领域模型与状态机

统一采用仓库已建议的状态契约，禁止以中文字符串或 Boolean 组合决定安全状态：

```text
ConnectionPhase = idle | resolving | connecting | handshaking
                | awaitingHostKeyDecision | authenticating | openingTerminal
                | connected | reconnecting(attempt, nextRetryAt)
                | disconnecting | disconnected(reason)
                | blocked(blockReason) | failed(error, retryable) | cancelled
```

同时维护可组合子状态：`HostKeyState`、`AuthState`、`KeepAliveState` 和 `ChannelState`。`SessionUiState` 至少包含资产 ID、会话 ID、phase、最近错误、安全状态、是否可重连、终端 channel 状态和可用工具集合。

强制规则：

1. unknown Host Key 只能展示指纹、取消和“信任此服务器”；保存成功后重新发起连接。
2. changed、revoked、unsupported Host Key 永远映射到 `blocked`，不可出现“仍然连接”按钮。
3. Terminal、SFTP、Monitor、Docker、Batch 只接受 verified session lease；lease 失效即停止子服务。
4. 网络切换、超时和后台被系统终止必须转为可解释的 `disconnected/failed`，不得把旧的连接图标留在绿色。

## 6. Rust binding 与终端实现

### Binding 方案

1. 为 checked connect、Host Key challenge、terminal、SFTP、Monitor、Docker 建立稳定的 Rust facade，输入输出使用 typed DTO，错误用受控 code + message，而非解析字符串。
2. 用 UniFFI 生成 Kotlin binding；将 native session/channel 作为不透明 Rust resource，由 Kotlin 持有可关闭 handle。
3. Kotlin 侧以 `suspend`/`Flow` 包装 native callback：连接 outcome、Host Key challenge、terminal output、连接中断和文件传输进度均可观察、可取消。
4. 保留现有 portable-sync JNI 以避免无关迁移；新接口不继续扩张手写 `extern fun`。
5. 所有 native 回调通过结构化并发回到 repository，不允许直接修改 Compose state。

### 终端

- 选择成熟、维护活跃并可支持 VT/xterm、Unicode、OSC、鼠标/选择、软硬键盘输入的 Android terminal renderer；先用独立技术验证确认性能、许可证、复制选择和 IME 行为，再决定引入或封装。
- 第一阶段支持单会话、滚动回溯、复制/粘贴、搜索、字体/字号、深浅终端主题、横屏、Ctrl/Alt/Esc/Tab/方向键扩展键条，以及实体键盘快捷键。
- 输出采用 bounded ring buffer 与批量帧刷新；禁止每个字节触发 Compose 重组。大输出、ANSI 转义、中文宽字符、emoji、窗口 resize 需回归测试。
- 终端页面进入后台时由 session policy 决定保活或断开；回到前台必须重新检查 native session 和 UI phase。

## 7. 数据、安全与同步

### 本地持久化

| 数据 | 存储位置 | 规则 |
| --- | --- | --- |
| 资产元数据、分组、标签、sync shadow、队列 | Room | 不得存密码、私钥或私钥口令 |
| 密码、私钥、私钥口令、会话解锁材料 | Android Keystore 包装的加密存储 | 使用 per-record alias；支持生物识别/设备凭据门控 |
| 主题、字号、连接策略等非敏感偏好 | DataStore | 有 schema 与迁移；不写入普通日志 |
| known_hosts / 信任记录 | 由 `orbit-core` 管理的应用私有文件 | 禁止放入公共存储或云端同步 blob |

### 同步

- 严格使用 `PortableServerConfig v1`、Rust `orbit_encrypt_config`/`orbit_decrypt_config` 和 vector clock；actor 固定为 `android`。
- 上传前把配置及所有敏感字段写入同一个加密 blob；不得上传 Android SAF URI、文件绝对路径或 Keystore alias。
- 409 后基于本地 shadow 做字段级合并。无冲突字段静默合并；同字段冲突进入脱敏对比页，由用户选择本地或云端。
- WorkManager 负责网络允许时的可延后同步；手动同步提供即时进度、失败原因和重试。后台任务不持有明文主密码。

### 安全控制

- 禁止明文日志、截图中显示私钥/密码、剪贴板无限期保存敏感值；粘贴私钥后建议清理剪贴板。
- Release 关闭调试日志，诊断导出默认脱敏且由用户确认生成。
- Telnet 默认关闭，必须在设置页确认风险，并针对每个目标再次确认；SSH 失败不能自动降级为 Telnet。
- 根目录检测、屏幕录制检测可作为风险提示，不应承诺绝对防护或阻断所有正常使用。

## 8. Android 系统集成

- 连接在前台显示时由绑定服务管理；用户明确要求保持会话时使用带常驻通知的 Foreground Service，并提供“全部断开”操作。
- 监听网络能力变化，但仅在用户设置开启后实施有限自动重连：指数退避、最大次数、可取消；认证失败和 Host Key blocked 永不自动重试。
- 使用 WorkManager 处理同步、诊断上传（若后端支持）和非交互任务；不以 WorkManager 维持实时终端。
- 采用 Storage Access Framework 导入/导出私钥和文件，避免申请宽泛存储权限；SFTP 下载使用用户选择目录或应用私有下载区。
- 支持 edge-to-edge、DisplayCutout、分屏、横屏、大字体、TalkBack、动态字体缩放与硬件键盘。

## 9. UI 与无障碍规范

- 构建 `design` 层，定义 page/surface/text/accent 及 success/warning/danger/connection* 语义 token；安全色不得被装饰主题覆盖。
- 普通文本对比度至少 4.5:1，非文本状态与大字至少 3:1；状态必须有文本/图标，不能仅靠颜色。
- Host Key 指纹采用可复制等宽文本，提供完整值和清晰风险说明；危险操作使用明确动词。
- 尊重系统 Reduce Motion、动画缩放、深色模式和字号；列表不叠加实时模糊，终端输出区域避免昂贵动画。
- 建立手机（360dp）、大屏（600dp+）、横屏、深浅色、字体 200%、TalkBack 的截图和交互验收集。

## 10. 分阶段实施与验收

| 阶段 | 交付 | 完成标准 |
| --- | --- | --- |
| A. 基础工程 | Hilt、Room、DataStore、导航、设计 token、CI、ABI 构建 | demo 数据移除；可在真机/模拟器启动；lint、unit test、格式化通过 |
| B. 资产与安全存储 | 登录、资产 CRUD、导入密钥、Keystore、同步队列 | 普通 DB 无敏感字段；配置能加密同步并完成冲突处理 |
| C. Checked SSH + 终端 | UniFFI binding、Host Key 流、连接状态机、终端 MVP | unknown 可确认；changed/revoked 必阻断；稳定完成连接、断开、重连与终端输入输出 |
| D. 移动端体验 | 键盘扩展栏、会话管理、前台服务、网络变化、诊断 | 后台/前台/切网状态正确；不会泄露会话或错误显示在线 |
| E. SFTP | 浏览、上传、下载、进度、冲突处理、SAF | 仅 verified session 可用；中断/恢复/失败状态可解释 |
| F. 运维能力 | Monitor、Docker、Snippet、Batch（仅允许的范围） | 每项复用 verified lease；Docker rename/update 保持禁用 |
| G. 发布加固 | 全 ABI、性能、无障碍、隐私、商店材料、灰度 | 无 P0/P1 安全缺陷；真机矩阵、网络矩阵、回归和发布门禁通过 |

## 11. 测试与发布门禁

### 自动化测试

- 单元测试：状态机转换、错误映射、repository、同步合并、Keystore 抽象、终端输入映射。
- Rust/FFI 合约测试：Kotlin binding 与 `orbit-core` checked outcome、Host Key challenge、portable sync fixture 完全一致。
- UI 测试：资产编辑、Host Key unknown/changed、失败重试、SFTP 传输、设置和深色/大字体。
- 端到端测试：容器化 OpenSSH 覆盖密码、密钥、未知 key、已变更 key、超时、断网和重连；继承现有 OpenSSH smoke 的安全案例。
- 性能测试：大输出终端帧率/内存、1,000+ 资产列表、SFTP 大文件、冷启动、ANR 和电量。

### 发布阻断条件

1. Release APK/AAB 不含 debug native 库或明文敏感日志。
2. Host Key changed/revoked/unsupported 无任何可绕过 UI 或 fallback 路径。
3. Room、DataStore、崩溃报告和诊断包均未发现密码、私钥、口令或 raw terminal 内容。
4. 所有发布 ABI 能加载对应 `liborbit_core.so`，并完成 binding smoke test。
5. 核心流程在最低 Android 版本、主流 Android 版本、横屏/大屏和至少一台实体设备通过。

## 12. 首个开发迭代的可执行清单

1. 移除 `MainScreen.kt` 的硬编码 demo 数据，建立 Hilt、Room schema、DataStore 和 AppNavigation。
2. 为资产、凭据、连接与同步定义 domain model，并实现 `ConnectionPhase` sealed model。
3. 接入真实 AssetRepository 与 Android Keystore credential store，补 migrate/import tests。
4. 设计 Rust checked-SSH facade 与 UniFFI 绑定 PoC；先跑通 connect → unknown key challenge → trust → terminal open → disconnect 的最小闭环。
5. 在此闭环稳定后接入终端 renderer，完成软键盘/实体键盘、横屏和大输出验证。

该顺序把安全连接和数据边界放在视觉完善之前，避免在静态 UI 上堆叠无法发布的功能。后续每个功能 PR 都应明确：使用的 verified session 条件、生命周期 owner、敏感数据边界、失败状态与测试证据。
