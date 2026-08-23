import SwiftUI

@MainActor
final class AppThemeManager: ObservableObject {
    static let themeStorageKey = "orbitterm.appearance.theme.id"
    static let modeStorageKey = "orbitterm.appearance.mode"

    @Published private(set) var selectedTheme: AppThemeID
    @Published private(set) var appearanceMode: AppearanceMode
    private let defaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        defaults = userDefaults
        selectedTheme = .resolved(userDefaults.string(forKey: Self.themeStorageKey))
        appearanceMode = .resolved(userDefaults.string(forKey: Self.modeStorageKey))
    }

    var palette: AppThemePalette { palette(for: .light) }
    var preferredColorScheme: ColorScheme? { appearanceMode.preferredColorScheme }

    func palette(for systemColorScheme: ColorScheme) -> AppThemePalette {
        let scheme = appearanceMode.preferredColorScheme ?? systemColorScheme
        return AppThemePalette.make(theme: selectedTheme, colorScheme: scheme)
    }

    func selectTheme(_ theme: AppThemeID) {
        guard selectedTheme != theme else { return }
        selectedTheme = theme
        defaults.set(theme.rawValue, forKey: Self.themeStorageKey)
    }

    func selectMode(_ mode: AppearanceMode) {
        guard appearanceMode != mode else { return }
        appearanceMode = mode
        defaults.set(mode.rawValue, forKey: Self.modeStorageKey)
    }
}

#if os(macOS)
/// The small, user-customisable set of workstation commands. Tab selection
/// stays ⌘1…⌘9 because those positions are a stable navigation convention.
enum WorkstationShortcutAction: String, CaseIterable, Identifiable, Codable {
    case addServer, newTab, closeTab, focusServerSearch, refreshCurrentTool
    case refreshMonitor, focusSFTPPath, goToSFTPParent, disconnectSession, settings, showHelp

    var id: String { rawValue }
    var title: String {
        switch self {
        case .addServer: "添加服务器"; case .newTab: "新建标签"; case .closeTab: "关闭标签"
        case .focusServerSearch: "聚焦服务器搜索"; case .refreshCurrentTool: "刷新当前工具"
        case .refreshMonitor: "立即刷新监控"; case .focusSFTPPath: "聚焦 SFTP 路径"
        case .goToSFTPParent: "返回 SFTP 上级目录"; case .disconnectSession: "断开当前会话"
        case .settings: "打开设置"; case .showHelp: "显示快捷键说明"
        }
    }
    var defaultShortcut: WorkstationShortcut {
        switch self {
        case .addServer: .command("n"); case .newTab: .command("t"); case .closeTab: .command("w")
        case .focusServerSearch: .command("k"); case .refreshCurrentTool: .command("r")
        case .refreshMonitor: .command("r", shift: true); case .focusSFTPPath: .command("f", shift: true)
        case .goToSFTPParent: .command("["); case .disconnectSession: .command("w", shift: true)
        case .settings: .command(","); case .showHelp: .command("?")
        }
    }
}

/// A persisted macOS Command / Command-Shift shortcut. Other modifier sets
/// are deliberately not accepted so global system shortcuts remain protected.
struct WorkstationShortcut: Codable, Hashable {
    let key: String
    let includesShift: Bool
    static func command(_ key: Character, shift: Bool = false) -> Self { .init(key: String(key).lowercased(), includesShift: shift) }
    var displayString: String { "⌘\(includesShift ? "⇧" : "")\(key.uppercased())" }
    var keyEquivalent: KeyEquivalent { KeyEquivalent(Character(key)) }
    var modifiers: EventModifiers { includesShift ? [.command, .shift] : [.command] }
    var isSupported: Bool {
        guard key.count == 1, let scalar = key.unicodeScalars.first else { return false }
        return scalar.isASCII && !CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

enum WorkstationShortcutAssignmentResult: Equatable { case accepted, duplicate(WorkstationShortcutAction), reserved, unsupported }

@MainActor
final class WorkstationShortcutPreferences: ObservableObject {
    static let storageKey = "orbitterm.workstation.shortcuts.v1"
    @Published private(set) var assignments: [WorkstationShortcutAction: WorkstationShortcut]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults; assignments = Self.load(from: defaults) }
    func shortcut(for action: WorkstationShortcutAction) -> WorkstationShortcut { assignments[action] ?? action.defaultShortcut }
    @discardableResult func assign(_ shortcut: WorkstationShortcut, to action: WorkstationShortcutAction) -> WorkstationShortcutAssignmentResult {
        guard shortcut.isSupported else { return .unsupported }
        guard !Self.reservedShortcuts.contains(shortcut) else { return .reserved }
        if let conflict = WorkstationShortcutAction.allCases.first(where: { $0 != action && self.shortcut(for: $0) == shortcut }) { return .duplicate(conflict) }
        assignments[action] = shortcut; persist(); return .accepted
    }
    func reset(_ action: WorkstationShortcutAction) { assignments[action] = action.defaultShortcut; persist() }
    func resetAll() { assignments = Self.defaultAssignments; persist() }

    private static var defaultAssignments: [WorkstationShortcutAction: WorkstationShortcut] { Dictionary(uniqueKeysWithValues: WorkstationShortcutAction.allCases.map { ($0, $0.defaultShortcut) }) }
    private static let reservedShortcuts: Set<WorkstationShortcut> = [.command("q"), .command("h"), .command("m")]
    private static func load(from defaults: UserDefaults) -> [WorkstationShortcutAction: WorkstationShortcut] {
        guard let data = defaults.data(forKey: storageKey), let decoded = try? JSONDecoder().decode([String: WorkstationShortcut].self, from: data) else { return defaultAssignments }
        var result = defaultAssignments
        for action in WorkstationShortcutAction.allCases where decoded[action.rawValue]?.isSupported == true { result[action] = decoded[action.rawValue] }
        return Set(result.values).count == result.count ? result : defaultAssignments
    }
    private func persist() {
        let encoded = Dictionary(uniqueKeysWithValues: assignments.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
#endif
