# 五套跨平台应用主题实施计划

目标主题 ID：`sky-candy`、`emerald-flow`、`peach-dawn`、`lavender-mist`、`glacier-mint`。本计划不改变终端 ANSI 配色，并按可独立验证的阶段拆分。

## 设计原则

- AppTheme 与 TerminalTheme 是两个模型、两个存储键、两个选择器。
- 共享的是 ID 与 semantic token 契约，不是跨端 UI 代码。
- Host Key、认证、错误、危险操作、成功与连接状态使用固定语义色；外观主题只能提供满足对比要求的映射。
- 系统浅/暗色是 AppTheme 的变体/模式，不与 terminal dark/light theme 绑定。

## 阶段 1：主题规范和状态模型

新增平台无关的文档/JSON 契约，定义五个 ID、required token、token fallback 与 `ConnectionPhase`。验收：每个主题均含完整 token；禁止 `ansi16` 与 terminal 字段；状态 token 的对比度检查通过。

## 阶段 2：主题管理器和持久化

- Apple：新增 `AppTheme`、`AppThemeManager`、`@AppStorage("orbitterm.appearance.theme.id")` 与 `appearance.mode`。
- Windows：新增 `ThemeService`、应用级 `ResourceDictionary` 与 LocalSettings 持久化。
- Android：新增 `AppThemeId`、Compose `CompositionLocal` / `ColorScheme` adapter、DataStore preferences。

验收：切换立刻刷新 chrome；重启后恢复；终端 `orbitterm.terminal.theme.id` 完全不变。

## 阶段 3：登录页

迁移 `AuthView.swift`、`AuthVisualComponents.swift`、`MasterPasswordGateView.swift` 的硬编码渐变、Material、阴影与表单 surface。验收：五主题 × system light/dark；输入/disabled/focus/error 对比度通过。

## 阶段 4：主工作台

迁移 Apple `ContentView.swift`、`MainWorkstationView.swift`、`TabBarView.swift`、sidebar、right panel、SFTP card、Docker card、Monitor card。桌面端背景 glow 只放在根容器；列表与 SwiftTerm terminal 区域使用可读/不透明 surface。

## 阶段 5：设置页和主题选择器

在 Apple `SettingsView.swift` 增加“应用外观”段，位置与“终端外观”并列但严格分开；主题卡片展示 page/surface/accent 预览，终端段仍仅显示 terminal palette。Windows/Android 同样分离页面。验收：更改 AppTheme 不改变 TerminalTheme preview/实际 palette。

## 阶段 6：SSH 状态组件

先引入 `ConnectionPhase` adapter，再将 tab dot、sidebar indicator、连接按钮、状态 banner 从 `isConnected` 与字符串判断迁移。验收：connecting/reconnecting/disconnected/blocked 都有图标、文本、非颜色线索。

## 阶段 7：Host Key 和危险状态

迁移 `HostKeyTrustViews.swift`、`TelnetRiskConfirmationView.swift`、SFTP destructive alerts、Docker remove/kill action。Host Key changed/revoked 永远使用 `connectionBlocked`/`danger`；信任 unknown host 使用 explicit action，不随 app accent 改变风险语义。验收：高对比/五主题下正文和指纹可读、操作不误导。

## 阶段 8：桌面端适配

macOS：Material 支持矩阵、窗口背景和 `NavigationSplitView`。Windows：自有 `ThemeResource` key 与 Mica/Acrylic fallback；不要覆盖全局 WinUI control colors。验收：窗口、menu、sidebar、tab、card、dialog 统一；High Contrast fallback 可用。

## 阶段 9：移动端适配

iOS：Tab bar、NavigationStack、safe area、keyboard accessory、动态字体。Android：把 `OrbitTheme.kt` 从二色方案扩展为五 ID × light/dark，并在 SSH 功能落地时复用状态 token。验收：小屏、横竖屏、字体放大、深色模式。

## 阶段 10：可访问性和性能

实现 Reduce Motion / Reduce Transparency / High Contrast 降级；禁用列表单元实时 blur 和无限 glow animation；对 SwiftTerm、Lazy lists 与 Monitor 刷新进行 Instruments/平台 profiler 验证。验收：降级时仍保留层级、focus ring 和状态辨识。

## 阶段 11：自动化测试

- token completeness、ID migration、fallback、contrast lint；
- Apple XCTest：终端 palette 不随 AppTheme 改变，Host Key/危险 token 不被 accent 覆盖；
- Windows xUnit：ResourceDictionary/ThemeService 映射；
- Android unit/Compose tests：theme selector/persistence；
- UI snapshot：登录、工作台、设置、Host Key、连接失败，五主题 × light/dark。

## 主题映射建议

| ID | 装饰方向 | 不可变安全策略 |
|---|---|---|
| sky-candy | 天蓝 + 糖果粉紫背景 glow | danger 保持高可辨红，blocked 不使用粉色 accent |
| emerald-flow | 翡翠/青绿流光 | success 与 accent 分离，success 不能仅靠翡翠色 |
| peach-dawn | 蜜桃暖光、低饱和晨色 | warning/danger 采用独立深琥珀/红色以确保对比 |
| lavender-mist | 薰衣草雾面与冷紫 | focus ring 与 disabled text 不可过低对比 |
| glacier-mint | 冰蓝薄荷、清透表面 | 表单与终端外围需要不透明 fallback，避免浅色文字丢失 |

## 不在代码阶段完成的验证

需要人工设备/账号的 Apple 签名、公证、App Store 验证、真实 SSH/OpenSSH、VoiceOver 真机与低端 Android 设备性能验证应在代码改造后执行，不应阻塞 semantic token 和自动化单测的落地。
