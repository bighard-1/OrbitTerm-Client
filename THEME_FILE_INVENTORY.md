# 主题改造文件清单

风险：高 = 容易影响安全语义或 SSH/terminal；中 = 影响大量界面或原生资源；低 = 独立样式/测试。

## Apple

| 文件路径 | 当前职责 | 需要修改的内容 | 建议新增类型/组件 | 风险 | 测试 |
|---|---|---|---|---|---|
| `project.yml` | XcodeGen 项目源 | 注册新增主题源/测试文件 | 无 | 低 | 是，XcodeGen 一致性 |
| `OrbitTerm/App/OrbitTermApp.swift` | App 生命周期与 deep link | 注入 AppTheme environment / scene 外观 | `AppThemeProvider` | 中 | 是 |
| `OrbitTerm/App/ContentView.swift` | macOS/iOS 根导航和移动 shell | 根背景、tab chrome、sync banner token 化 | `AppChromeBackground` | 高 | snapshot |
| `OrbitTerm/Features/Auth/AuthView.swift` | 登录/注册容器 | 渐变、Material、shadow token 化 | `ThemeSurface` | 中 | snapshot |
| `OrbitTerm/Features/Auth/AuthVisualComponents.swift` | 登录表单组件 | button/input/message 状态 token 化 | `ThemedInputStyle` | 中 | unit/UI |
| `OrbitTerm/Features/Security/MasterPasswordGateView.swift` | 解锁安全页 | 背景/消息状态分离 | `SecurityMessageStyle` | 高 | snapshot/a11y |
| `OrbitTerm/Features/Home/MainWorkstationView.swift` | macOS 主工作台 | column surface、transition、status capsule | `WorkspaceTheme` | 高 | snapshot/perf |
| `OrbitTerm/Features/Home/TabBarView.swift` | 会话标签 | active/dot/border 改为 connection token | `ConnectionIndicator` | 高 | unit/snapshot |
| `OrbitTerm/Features/Home/WorkstationAssetSidebarView.swift` | 资产侧栏 | selection、session dot、card token 化 | `ConnectionIndicator` | 中 | snapshot |
| `OrbitTerm/Features/Home/WorkstationRightPanelView.swift` | Monitor/SFTP/Docker/sidebar 容器 | card/surface/divider token 化 | `ThemedPanel` | 中 | snapshot |
| `OrbitTerm/Features/Home/SFTPBrowser*.swift` | SFTP 视图与交互 | list selection、error/success、dialog surface | `ThemedListRow` | 高 | UI |
| `OrbitTerm/Features/Home/Docker*.swift` | Docker UI | action/result/destructive token 化 | `DangerActionStyle` | 高 | UI |
| `OrbitTerm/Features/Home/SettingsView.swift` | 设置 + terminal themes | 新增 AppTheme selector；保留 terminal selector 独立 | `AppThemeManager` | 高 | unit/UI |
| `OrbitTerm/Features/Home/SwiftTermTerminalView.swift` | SwiftTerm wrapper | 不读取 AppTheme；增加隔离断言/测试钩子 | `TerminalTheme`（保持独立） | 高 | regression |
| `OrbitTerm/Features/Security/HostKeyTrustViews.swift` | Host Key fingerprint/challenge/blocked UI | 使用固定安全 token + contrast fallback | `SecuritySemanticPalette` | 高 | unit/a11y |
| `OrbitTerm/Features/Security/TelnetRiskConfirmationView.swift` | Telnet 危险确认 | warning/danger token 化 | `DangerActionStyle` | 高 | snapshot |
| `OrbitTermCheckedFFITests/*` | macOS XCTest | 加 AppTheme/terminal isolation/Host Key contrast tests | `AppThemeTests` | 中 | 是 |

## Windows

| 文件路径 | 当前职责 | 需要修改的内容 | 建议新增类型/组件 | 风险 | 测试 |
|---|---|---|---|---|---|
| `clients/windows/src/OrbitTerm.App/App.xaml` | 全局 WinUI resources | 合并自有 theme dictionaries | `Themes/*.xaml` | 中 | 是 |
| `clients/windows/src/OrbitTerm.App/App.xaml.cs` | DI/launch | 初始化 ThemeService | `ThemeService` | 中 | 是 |
| `clients/windows/src/OrbitTerm.App/MainWindow.xaml` | Windows 主 chrome / 工作台 | 只替换自有 semantic resource keys | `OrbitThemeResourceDictionary` | 高 | UI/manual |
| `clients/windows/src/OrbitTerm.Presentation/WorkspaceTabViewModel.cs` | tab 与状态文本 | 暴露 typed connection phase，禁止颜色字符串判断 | `ConnectionPhase` | 高 | xUnit |
| `clients/windows/src/OrbitTerm.Presentation/MainWindowViewModel.cs` | UI orchestration | 状态 → semantic appearance adapter | `ConnectionAppearance` | 中 | xUnit |
| `clients/windows/tests/OrbitTerm.Security.Tests/*` | Windows tests | Theme/state mapping tests | `ThemeServiceTests` | 中 | 是 |

当前仓库未发现 Windows 终端 renderer 或 ANSI palette 定义；不得假设可与 Apple `TerminalTheme` 共用 UI 实现。

## Android

| 文件路径 | 当前职责 | 需要修改的内容 | 建议新增类型/组件 | 风险 | 测试 |
|---|---|---|---|---|---|
| `clients/android/.../ui/theme/OrbitTheme.kt` | Material 亮/暗主题 | 五套 ID × mode → ColorScheme，提供 CompositionLocal | `AppThemeId`, `OrbitAppearance` | 中 | unit/Compose |
| `clients/android/.../MainActivity.kt` | Compose root | 注入 theme preference | `ThemeViewModel` | 低 | Compose |
| `clients/android/.../ui/MainScreen.kt` | 当前移动壳 | surface/card/nav token 化 | `ThemedScaffold` | 中 | snapshot |
| `clients/android/.../OrbitTermAndroidApp.kt` | Application | 初始化 DataStore/theme repository | `ThemeRepository` | 低 | unit |
| `clients/android/.../core/OrbitCoreBridge.kt` | JNI portable sync bridge | 不加入应用主题或 ANSI 控制 | 无 | 高 | regression |

Android 当前仓库未发现 SSH terminal、ANSI palette、Host Key UI、SFTP、Monitor、Docker、Port Forwarding 状态文件；这些项目在功能实现后才有对应主题改造文件。

## 当前已存在的关键 UI 文件

| 界面 | Apple 实际路径 | Windows 实际路径 | Android 实际路径 |
|---|---|---|---|
| 登录/注册 | `OrbitTerm/Features/Auth/AuthView.swift` | 当前仓库未发现独立登录页 | 当前仓库未发现 |
| 服务器列表 | `Features/Home/ServerListView.swift` / `WorkstationAssetSidebarView.swift` | `MainWindow.xaml` + `MainWindowViewModel.cs` | `ui/MainScreen.kt` |
| 添加/编辑服务器 | `Features/Home/AddServerView.swift` | `MainWindow.xaml` / `MainWindowViewModel.cs` | 当前仓库未发现 |
| 主工作台 | `Features/Home/MainWorkstationView.swift` | `OrbitTerm.App/MainWindow.xaml` | 当前仓库未发现完整工作台 |
| 终端 | `Features/Home/SwiftTermTerminalView.swift`、`WorkstationTerminalSessionPane.swift` | `MainWindow.xaml`、`TerminalLineViewModel.cs` | 当前仓库未发现 |
| 会话标签 | `Features/Home/TabBarView.swift` | `MainWindow.xaml`、`WorkspaceTabViewModel.cs` | 当前仓库未发现 |
| SFTP | `Features/Home/SFTPBrowserView.swift` 等 | `MainWindow.xaml`、Application SFTP result types | 当前仓库未发现 |
| 设置 | `Features/Home/SettingsView.swift` | 当前仓库未发现独立设置页 | 当前仓库未发现 |
| Host Key 指纹确认 | `Features/Security/HostKeyTrustViews.swift` | `MainWindow.xaml` + `HostKeyTrustModels.cs` | 当前仓库未发现 |
| 连接失败 / 自动重连提示 | `SessionManager.swift` 的 status + terminal 文案；无独立 view 文件 | `MainWindow.xaml` 状态区 + ViewModel | 当前仓库未发现 |
| 危险操作确认 | `TelnetRiskConfirmationView.swift`、`WorkstationSheetsAndAlerts.swift`、SFTP dialogs | `MainWindow.xaml.cs` 相关 dialog handlers | 当前仓库未发现 |
| 桌面窗口外壳 | `ContentView.swift` / `MainWorkstationView.swift`（macOS） | `App.xaml`、`MainWindow.xaml` | 不适用 |
| 移动导航外壳 | `ContentView.swift`（iOS `TabView`） | 不适用 | `MainScreen.kt`（NavigationBar） |

## 样式相关文件的完整检索清单

以下清单来自对 SwiftUI 的颜色、字体、圆角/阴影、Material、颜色环境和 `AppStorage` 引用，以及 Windows XAML 的 Theme/ResourceDictionary/Brush、Android Compose 的 MaterialTheme/Color 的检索。它是主题迁移的完整审计候选集合；其中少数文件只含字体或持久化引用，实施时应按 token 使用情况确认是否需要改动。

### Apple SwiftUI

```text
OrbitTerm/App/ContentView.swift
OrbitTerm/App/MobileSessionComponents.swift
OrbitTerm/App/MobileSessionViews.swift
OrbitTerm/Core/CredentialInputHelpers.swift
OrbitTerm/Core/DeepLinkManager.swift
OrbitTerm/Features/Auth/AuthView.swift
OrbitTerm/Features/Auth/AuthVisualComponents.swift
OrbitTerm/Features/Home/AddServerAuthSection.swift
OrbitTerm/Features/Home/AddServerFormComponents.swift
OrbitTerm/Features/Home/AddServerInitialState.swift
OrbitTerm/Features/Home/AddServerView.swift
OrbitTerm/Features/Home/AssetBulkAddSheet.swift
OrbitTerm/Features/Home/AssetManagerView.swift
OrbitTerm/Features/Home/AssetQuickKeySetupSheet.swift
OrbitTerm/Features/Home/BatchCommandRunnerView.swift
OrbitTerm/Features/Home/DetachedSessionWindowView.swift
OrbitTerm/Features/Home/DiagnosticsExportView.swift
OrbitTerm/Features/Home/DockerCardView.swift
OrbitTerm/Features/Home/DockerLogStreamView.swift
OrbitTerm/Features/Home/DockerManagerView.swift
OrbitTerm/Features/Home/MainWorkstationView.swift
OrbitTerm/Features/Home/MonitorDashboardView.swift
OrbitTerm/Features/Home/RecentlyDeletedView.swift
OrbitTerm/Features/Home/SFTPBrowserComponents.swift
OrbitTerm/Features/Home/SFTPBrowserPanels.swift
OrbitTerm/Features/Home/SFTPBrowserView.swift
OrbitTerm/Features/Home/ServerListView.swift
OrbitTerm/Features/Home/SettingsView.swift
OrbitTerm/Features/Home/SnippetsPanelView.swift
OrbitTerm/Features/Home/SwiftTermTerminalView.swift
OrbitTerm/Features/Home/TabBarView.swift
OrbitTerm/Features/Home/WorkstationAssetSidebarView.swift
OrbitTerm/Features/Home/WorkstationCollapsedFeatureRow.swift
OrbitTerm/Features/Home/WorkstationDockerCardView.swift
OrbitTerm/Features/Home/WorkstationMonitorCardView.swift
OrbitTerm/Features/Home/WorkstationMonitorDetailViews.swift
OrbitTerm/Features/Home/WorkstationRightPanelView.swift
OrbitTerm/Features/Home/WorkstationSFTPCardView.swift
OrbitTerm/Features/Home/WorkstationSFTPDialogs.swift
OrbitTerm/Features/Home/WorkstationSnippetsCardView.swift
OrbitTerm/Features/Home/WorkstationTerminalDropUploadModifier.swift
OrbitTerm/Features/Home/WorkstationTerminalSearchOverlay.swift
OrbitTerm/Features/Home/WorkstationTerminalSessionChrome.swift
OrbitTerm/Features/Home/WorkstationTerminalSessionPane.swift
OrbitTerm/Features/Home/WorkstationTerminalSplitLayoutView.swift
OrbitTerm/Features/Home/WorkstationTerminalToolbarView.swift
OrbitTerm/Features/Home/WorkstationToolbarModifier.swift
OrbitTerm/Features/Security/HostKeyTrustViews.swift
OrbitTerm/Features/Security/MasterPasswordGateView.swift
OrbitTerm/Features/Security/TelnetRiskConfirmationView.swift
```

### Windows

```text
clients/windows/src/OrbitTerm.App/App.xaml
clients/windows/src/OrbitTerm.App/MainWindow.xaml
clients/windows/src/OrbitTerm.App/MainWindow.xaml.cs
```

### Android

```text
clients/android/OrbitTermAndroid/app/src/main/AndroidManifest.xml
clients/android/OrbitTermAndroid/app/src/main/java/com/orbitterm/android/MainActivity.kt
clients/android/OrbitTermAndroid/app/src/main/java/com/orbitterm/android/ui/MainScreen.kt
clients/android/OrbitTermAndroid/app/src/main/java/com/orbitterm/android/ui/theme/OrbitTheme.kt
clients/android/OrbitTermAndroid/app/src/main/res/values/styles.xml
```
