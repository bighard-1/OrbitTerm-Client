import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
/// Presentation-only actions published by the active workstation window.
/// Menu commands use this focused value instead of reaching into view state or
/// interpreting terminal keystrokes globally.
struct WorkstationShortcutActions {
    let addServer: () -> Void
    let openNewTab: () -> Void
    let closeActiveTab: () -> Void
    let canCloseActiveTab: Bool
    let activateTab: (Int) -> Void
    let activateTerminalPane: (Int) -> Void
    let terminalPaneCount: Int
    let focusServerSearch: () -> Void
    let refreshCurrentTool: () -> Void
    let canRefreshCurrentTool: Bool
    let refreshMonitor: () -> Void
    let canRefreshMonitor: Bool
    let focusSFTPPath: () -> Void
    let canFocusSFTPPath: Bool
    let goToSFTPParent: () -> Void
    let canGoToSFTPParent: Bool
    let disconnectActiveSession: () -> Void
    let canDisconnectActiveSession: Bool
    let showSettings: () -> Void
    let showShortcutHelp: () -> Void
}

/// Per-app-window presentation router for native menu commands. It owns no
/// connection state: the active workstation installs its actions while visible
/// and clears them when it disappears.
@MainActor
final class WorkstationShortcutCoordinator: ObservableObject {
    @Published private(set) var actions: WorkstationShortcutActions?

    func install(_ actions: WorkstationShortcutActions) {
        self.actions = actions
    }

    func clear() {
        actions = nil
    }
}

private struct WorkstationMenuCommands: Commands {
    @ObservedObject var coordinator: WorkstationShortcutCoordinator
    @ObservedObject var preferences: WorkstationShortcutPreferences

    private var actions: WorkstationShortcutActions? {
        coordinator.actions
    }

    var body: some Commands {
        // Insert ahead of the system New command so ⌘N deterministically opens
        // the workstation's add-server sheet instead of creating a window.
        CommandGroup(before: .newItem) {
            Button("添加服务器") { actions?.addServer() }
                .keyboardShortcut(preferences.shortcut(for: .addServer).keyEquivalent, modifiers: preferences.shortcut(for: .addServer).modifiers)
                .disabled(actions == nil)

            Button("新建标签") { actions?.openNewTab() }
                .keyboardShortcut(preferences.shortcut(for: .newTab).keyEquivalent, modifiers: preferences.shortcut(for: .newTab).modifiers)
                .disabled(actions == nil)

            Button("关闭标签") { actions?.closeActiveTab() }
                .keyboardShortcut(preferences.shortcut(for: .closeTab).keyEquivalent, modifiers: preferences.shortcut(for: .closeTab).modifiers)
                .disabled(actions?.canCloseActiveTab != true)

            Divider()

            Button("标签 1") { actions?.activateTab(0) }
                .keyboardShortcut("1", modifiers: .command)
            Button("标签 2") { actions?.activateTab(1) }
                .keyboardShortcut("2", modifiers: .command)
            Button("标签 3") { actions?.activateTab(2) }
                .keyboardShortcut("3", modifiers: .command)
            Button("标签 4") { actions?.activateTab(3) }
                .keyboardShortcut("4", modifiers: .command)
            Button("标签 5") { actions?.activateTab(4) }
                .keyboardShortcut("5", modifiers: .command)
            Button("标签 6") { actions?.activateTab(5) }
                .keyboardShortcut("6", modifiers: .command)
            Button("标签 7") { actions?.activateTab(6) }
                .keyboardShortcut("7", modifiers: .command)
            Button("标签 8") { actions?.activateTab(7) }
                .keyboardShortcut("8", modifiers: .command)
            Button("标签 9") { actions?.activateTab(8) }
                .keyboardShortcut("9", modifiers: .command)
        }

        CommandMenu("工作站") {
            Button("聚焦服务器搜索") { actions?.focusServerSearch() }
                .keyboardShortcut(preferences.shortcut(for: .focusServerSearch).keyEquivalent, modifiers: preferences.shortcut(for: .focusServerSearch).modifiers)
                .disabled(actions == nil)

            Button("刷新当前工具") { actions?.refreshCurrentTool() }
                .keyboardShortcut(preferences.shortcut(for: .refreshCurrentTool).keyEquivalent, modifiers: preferences.shortcut(for: .refreshCurrentTool).modifiers)
                .disabled(actions?.canRefreshCurrentTool != true)

            Button("立即刷新监控") { actions?.refreshMonitor() }
                .keyboardShortcut(preferences.shortcut(for: .refreshMonitor).keyEquivalent, modifiers: preferences.shortcut(for: .refreshMonitor).modifiers)
                .disabled(actions?.canRefreshMonitor != true)

            Button("聚焦 SFTP 路径") { actions?.focusSFTPPath() }
                .keyboardShortcut(preferences.shortcut(for: .focusSFTPPath).keyEquivalent, modifiers: preferences.shortcut(for: .focusSFTPPath).modifiers)
                .disabled(actions?.canFocusSFTPPath != true)

            Button("返回 SFTP 上级目录") { actions?.goToSFTPParent() }
                .keyboardShortcut(preferences.shortcut(for: .goToSFTPParent).keyEquivalent, modifiers: preferences.shortcut(for: .goToSFTPParent).modifiers)
                .disabled(actions?.canGoToSFTPParent != true)

            Divider()

            Button("断开当前会话…") { actions?.disconnectActiveSession() }
                .keyboardShortcut(preferences.shortcut(for: .disconnectSession).keyEquivalent, modifiers: preferences.shortcut(for: .disconnectSession).modifiers)
                .disabled(actions?.canDisconnectActiveSession != true)

            Divider()

            Button("切换到分屏 1") { actions?.activateTerminalPane(0) }
                .keyboardShortcut(preferences.shortcut(for: .selectTerminalPane1).keyEquivalent, modifiers: preferences.shortcut(for: .selectTerminalPane1).modifiers)
                .disabled((actions?.terminalPaneCount ?? 0) < 1)
            Button("切换到分屏 2") { actions?.activateTerminalPane(1) }
                .keyboardShortcut(preferences.shortcut(for: .selectTerminalPane2).keyEquivalent, modifiers: preferences.shortcut(for: .selectTerminalPane2).modifiers)
                .disabled((actions?.terminalPaneCount ?? 0) < 2)
            Button("切换到分屏 3") { actions?.activateTerminalPane(2) }
                .keyboardShortcut(preferences.shortcut(for: .selectTerminalPane3).keyEquivalent, modifiers: preferences.shortcut(for: .selectTerminalPane3).modifiers)
                .disabled((actions?.terminalPaneCount ?? 0) < 3)
            Button("切换到分屏 4") { actions?.activateTerminalPane(3) }
                .keyboardShortcut(preferences.shortcut(for: .selectTerminalPane4).keyEquivalent, modifiers: preferences.shortcut(for: .selectTerminalPane4).modifiers)
                .disabled((actions?.terminalPaneCount ?? 0) < 4)
        }

        CommandGroup(replacing: .appSettings) {
            Button("设置…") { actions?.showSettings() }
                .keyboardShortcut(preferences.shortcut(for: .settings).keyEquivalent, modifiers: preferences.shortcut(for: .settings).modifiers)
                .disabled(actions == nil)
        }

        CommandGroup(after: .help) {
            Button("工作站快捷键") { actions?.showShortcutHelp() }
                .keyboardShortcut(preferences.shortcut(for: .showHelp).keyEquivalent, modifiers: preferences.shortcut(for: .showHelp).modifiers)
                .disabled(actions == nil)

            Divider()

            Button("关于 OrbitTerm") {
                NSApp.orderFrontStandardAboutPanel(nil)
            }

            Button("使用条款") {
                let alert = NSAlert()
                alert.messageText = "OrbitTerm 使用条款"
                alert.informativeText = OrbitLegalTerms.fullText
                alert.addButton(withTitle: "知道了")
                alert.runModal()
            }

            Button("检查更新") {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
                let alert = NSAlert()
                alert.messageText = "OrbitTerm \(version)"
                alert.informativeText = "当前开发版本尚未配置正式更新源。正式发布后将从签名更新通道检查新版本。"
                alert.addButton(withTitle: "知道了")
                alert.runModal()
            }
        }
    }
}
#endif

@main
struct OrbitTermApp: App {
    private let appLaunchSpan: PerformanceSignpost.Span
    @StateObject private var session: AppSession
    @StateObject private var serverStore = ServerStore.shared
    @StateObject private var syncService = SyncService()
    @StateObject private var diagnostics: DiagnosticsManager
    @StateObject private var appThemeManager = AppThemeManager()
    @ObservedObject private var sessionManager = SessionManager.shared
    #if os(macOS)
    @StateObject private var shortcutCoordinator = WorkstationShortcutCoordinator()
    @StateObject private var shortcutPreferences = WorkstationShortcutPreferences()
    #endif

    init() {
        appLaunchSpan = PerformanceSignpost.begin(.launch)
        let diagnostics = DiagnosticsManager()
        _diagnostics = StateObject(wrappedValue: diagnostics)
        NetworkService.shared.configureDiagnostics(diagnostics)
        _session = StateObject(
            wrappedValue: AppSession(uiTestLaunchState: AppUITestLaunchState.current)
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .injectAppTheme()
                // XCUITest drives the app through a screen-capture channel.
                // Its explicitly non-persistent launch states contain no real
                // account data, so do not let that transport mask the UI under
                // test. Public Release builds always resolve to `.standard`.
                .protectSensitiveScreenContent(
                    enabled: AppUITestLaunchState.current == .standard
                )
                .environmentObject(session)
                .environmentObject(serverStore)
                .environmentObject(syncService)
                .environmentObject(diagnostics)
                .environmentObject(appThemeManager)
                #if os(macOS)
                .environmentObject(shortcutCoordinator)
                .environmentObject(shortcutPreferences)
                #endif
                .onAppear {
                    // The span ends only once, even when SwiftUI re-renders
                    // the root or restores another window.
                    appLaunchSpan.finish()
                }
        }
        #if os(macOS)
        // The workstation's monitoring controls need enough horizontal room on
        // a first launch.  macOS still preserves a user's later resize choice.
        .defaultSize(width: 1360, height: 840)
        // Keep the native traffic-light controls while letting the workstation
        // render its own themed top bar below them.
        .windowStyle(.hiddenTitleBar)
        .commands { WorkstationMenuCommands(coordinator: shortcutCoordinator, preferences: shortcutPreferences) }
        #endif

        #if os(macOS)
        WindowGroup("监控详情", for: MonitorDetailWindowRoute.self) { route in
            if let value = route.wrappedValue {
                MonitorDetailWindowView(route: value)
                    .injectAppTheme()
                    .environmentObject(session)
                    .environmentObject(serverStore)
                    .environmentObject(syncService)
                    .environmentObject(diagnostics)
                    .environmentObject(appThemeManager)
            } else {
                ContentUnavailableView("无可用监控会话", systemImage: "chart.line.uptrend.xyaxis")
            }
        }
        .defaultSize(width: 920, height: 760)

        WindowGroup("会话分离", for: UUID.self) { value in
            if let sid = value.wrappedValue {
                DetachedSessionWindowView(sessionID: sid)
                    .injectAppTheme()
                    .environmentObject(session)
                    .environmentObject(serverStore)
                    .environmentObject(syncService)
                    .environmentObject(diagnostics)
                    .environmentObject(appThemeManager)
            } else {
                ContentUnavailableView("无可用会话", systemImage: "terminal")
            }
        }
        .defaultSize(width: 980, height: 640)
        #endif
    }

}
