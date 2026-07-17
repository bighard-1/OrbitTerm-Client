# OrbitTerm 跨平台应用主题技术审计

审计范围：仓库当前 Apple（iOS/macOS）、Windows、Android 与 `orbit-core`。本报告只审计，不改变客户端代码。

## 结论

可以接入 `sky-candy`、`emerald-flow`、`peach-dawn`、`lavender-mist`、`glacier-mint` 五套应用外观主题，但应先建立跨端语义 token 和独立持久化边界。Apple 端可先实施；Windows 可用 `ResourceDictionary` 接入；Android 已有 Material 3 入口但仍是 Alpha UI。终端主题必须保留为独立设置，绝不能由应用主题 token 推导或写入 ANSI 调色板。

当前最大的主题改造风险不是框架能力，而是 Apple SwiftUI 中分散的硬编码颜色/Material 与状态色复用。安全状态目前也混用 `.green`、`.orange`、`.red` 和 `Color.accentColor`，需要迁移到不可被装饰主题覆盖的安全语义 token。

## 一、项目技术栈

| 平台 | 实际框架与语言 | 最低版本 / 架构 | 构建方式 | 入口与主导航 |
|---|---|---|---|---|
| iOS / macOS | SwiftUI + Swift 5；终端为 SwiftTerm 1.11.2 | iOS 17、macOS 14；当前 macOS 与 iOS Simulator 均限定 arm64 | XcodeGen 读取 `project.yml`，链接 Rust 静态库；`scripts/build_apple_core.sh` 构建 core | `OrbitTerm/App/OrbitTermApp.swift`；`OrbitTerm/App/ContentView.swift` 按平台分出 `NavigationSplitView` / `TabView` |
| Windows | WinUI 3 / Windows App SDK、C#、.NET 9 | Windows 10 19041，x64 | `clients/windows/OrbitTerm.Windows.sln`，MSIX 工具链；完整 XAML 构建需要 Windows | `clients/windows/src/OrbitTerm.App/App.xaml`、`App.xaml.cs`；`MainWindow.xaml` |
| Android | Kotlin + Jetpack Compose + Material 3 | minSdk 26，target/compile SDK 36，arm64-v8a | Gradle Kotlin DSL；JNI `.so` 位于 `app/src/main/jniLibs/arm64-v8a/` | `MainActivity.kt` → `OrbitTheme` → `MainScreen.kt` |

共享业务核心是 Rust `orbit-core`：`Cargo.toml` 声明 `staticlib`、`cdylib` 与 `rlib`，实现 SSH、Host Key、checked FFI、SFTP、终端、Monitor、Docker、加密与 portable 同步。Apple 通过 C ABI/静态库连接，Windows 通过 checked C ABI，Android 已有同步相关 JNI wrapper；不存在共享 UI 模块。

## 二、现有主题与样式系统

### Apple

- 跟随系统：登录与若干组件读取 `@Environment(\\.colorScheme)`；没有发现 `preferredColorScheme` 或应用级外观选择器。
- 终端主题：`OrbitTerm/Features/Home/SettingsView.swift` 中 `TerminalThemeManager` 定义 Dracula、Solarized Dark、Nord、Homebrew，`@AppStorage("orbitterm.terminal.theme.id")` 保存选择。
- 应用主题：当前仓库未发现 `AppTheme`、`ThemeManager`、应用主题 ID、颜色资产 catalog 主题色或统一 token 层。
- 硬编码样式广泛存在：例如 `AuthView.swift`、`AuthVisualComponents.swift`、`MasterPasswordGateView.swift`、`ContentView.swift` 的 RGB 渐变；多处 `.ultraThinMaterial` / `.thinMaterial` / `.regularMaterial`；`TabBarView.swift`、`WorkstationAssetSidebarView.swift`、`SFTPBrowserComponents.swift` 使用 `.green`、`.orange`、`.blue`、`Color.accentColor`。
- 字体、圆角、阴影也主要散落在 View 中：常见 `RoundedRectangle(cornerRadius:)`、`Capsule`、`.shadow` 与系统字体调用，未发现共享 design-token 文件。
- 持久化：应用外观设置当前仓库未发现。终端、字号、Telnet、生物识别、监控间隔等使用 `@AppStorage` / `UserDefaults`；资产/同步另有 SQLite、Keychain 和 App Support 存储。

### Windows

- `App.xaml` 合并 `XamlControlsResources`，`MainWindow.xaml` 大量使用 `ThemeResource`，如 `CardBackgroundFillColorDefaultBrush`、`TextFillColorSecondaryBrush`、`AccentButtonStyle`、`DividerStrokeColorDefaultBrush`。
- 当前未发现自定义 `ResourceDictionary`、`RequestedTheme`、`ApplicationTheme` 持久化、Mica/Acrylic 配置或自定义调色板。
- 这意味着 Windows 已自然跟随 WinUI 系统资源，但尚不支持五套运行时主题。新增主题应在应用级 dictionary 中覆写自有 semantic key，不应覆写 WinUI 全局安全色语义。

### Android

- `clients/android/OrbitTermAndroid/app/src/main/java/com/orbitterm/android/ui/theme/OrbitTheme.kt` 使用 `isSystemInDarkTheme()` 在 `lightColorScheme` / `darkColorScheme` 间切换；未使用 dynamic color。
- 当前仅定义 primary、secondary、background、surface、error，其余 Material 色由默认推导；未发现主题 ID、DataStore/SharedPreferences 的外观持久化或运行时选择器。
- `MainScreen.kt` 主要使用 `MaterialTheme.colorScheme`，但 `RoundedCornerShape(22.dp)` 与若干 layout 数值硬编码。

## 三、终端主题与应用主题隔离

终端库是 SwiftTerm，封装位于 `OrbitTerm/Features/Home/SwiftTermTerminalView.swift` 与 `SwiftTermPlatformSupport.swift`。终端主题由 `TerminalTheme` 的 `background`、`foreground`、`ansi16` 控制，桥接层调用 `TerminalView.nativeBackgroundColor`、`nativeForegroundColor` 和 `installPalette(colors:)`。

当前终端配置包括前景、背景与 ANSI 16 色；当前仓库未发现对 256 色、光标色、选区色或搜索匹配色的显式配置。搜索使用 SwiftTerm 的 `findNext` / `findPrevious` 默认行为。应用外壳现在不会直接写入 `TerminalThemeManager`，因此已有基本隔离；但若把 `Color.accentColor` 或全局环境色扩展到 terminal wrapper，会破坏此边界。

建议的强制边界：

1. 定义独立 `AppThemeID` 与 `TerminalThemeID`，存储键分别为 `orbitterm.appearance.theme.id`、现有 `orbitterm.terminal.theme.id`。
2. `AppTheme` 模型中禁止 `ansi16`、terminal foreground/background、cursor、selection 字段；`TerminalTheme` 中禁止 page/surface/accent 字段。
3. 终端 View 只接收 `TerminalTheme`，不读取 `Environment` 的应用调色板；应用 chrome 可以包围终端容器，但不得覆盖 TerminalView 背景或 palette。
4. 对终端 wrapper 增加回归测试：切换五个 AppTheme 后，传入 SwiftTerm 的 16 色与前/背景完全不变。

## 四、状态色与无障碍风险

Host Key 已有不可继续的安全语义：`HostKeyBlockedPresentation.Severity` 为 changed、revoked、unsupported；未知 key 只提供取消/信任，已变更与撤销 key 不提供信任选项。`TelnetRiskConfirmationView.swift`、`HostKeyTrustViews.swift`、`SettingsView.swift` 还含危险性文案和 destructive action。

主题系统必须将 `success`、`warning`、`danger`、`information` 和 `connection*` 作为**安全语义层**，不允许五套装饰主题改变其含义或使文字对比度失效。每个主题都应提供 WCAG 对比验证：普通文字至少 4.5:1；大字与非文本 UI 指示至少 3:1；Host Key 指纹、错误码与危险确认不能只靠颜色传达。

## 五、性能与平台限制

| 平台 | 可用效果 | 主要风险 | 建议降级 |
|---|---|---|---|
| macOS | SwiftUI Material、渐变、阴影、动画，系统可合成 | 三栏工作台、终端、SFTP 列表上叠加动态模糊会增加合成成本 | 固定背景 glow；列表/终端区域不用实时 blur；Reduce Transparency 时改为不透明 `surfaceReadable` |
| iOS | SwiftUI Material、渐变、系统动画 | 小屏、低内存设备、滚动列表上的多层 Material、终端持续输出 | 不在 `List`/`LazyVStack` 每行做 blur；移动端限制为一层背景 glow；Reduce Motion 时禁用弹簧/循环动画 |
| Windows | WinUI theme resources；可选 Mica/Acrylic/Composition | Acrylic/Mica、阴影和虚拟化列表叠加可消耗 GPU | 默认只在窗口外壳使用 Mica；列表/card 使用不透明 surface；根据 High Contrast / transparency preference 降级 |
| Android | Compose 渐变、shape、elevation；后续可用 RenderEffect | Alpha 当前 UI 很轻，但低端设备实时 blur 昂贵 | 不把 blur 放进 LazyColumn item；采用预计算渐变和 elevation；读取系统 animator scale / accessibility 设置后关闭装饰动画 |

当前 Apple 代码只读取 `colorSchemeContrast` 于 Host Key 视图；未发现 Reduce Motion、Reduce Transparency 的应用级响应。Windows/Android 当前仓库未发现等效降级实现。

## 六、五套主题的推荐语义规范

五个跨端 ID：`sky-candy`、`emerald-flow`、`peach-dawn`、`lavender-mist`、`glacier-mint`。每个 ID 在各平台映射相同语义名、不同原生颜色/材质实现：

```text
pageBackground                 backgroundGlowPrimary          backgroundGlowSecondary
surfaceGlass                   surfaceGlassStrong             surfaceReadable
surfaceCritical                surfaceInput                   textPrimary
textSecondary                  textDisabled                   textOnAccent
accentPrimary                  accentSecondary                focusRing
borderGlass                    divider                        success
warning                        danger                         information
connectionConnected            connectionConnecting           connectionReconnecting
connectionDisconnected         connectionBlocked
```

额外约束：

- `danger`、`warning`、`success`、`connectionBlocked` 必须是固定安全调色板或至少受对比度/色相范围约束，不能仅随 candy/peach/lavender 装饰色推导。
- `surfaceCritical` 是危险确认容器，不能替代 `danger` 的文字/图标语义。
- `pageBackground`/glow 只用于 chrome；terminal 采用其自身 `TerminalTheme`。
- 每个平台可增加私有 token（例如 iOS `materialStyle`、Windows `AcrylicFallbackBrush`），但不得改变上述共享契约的含义。
