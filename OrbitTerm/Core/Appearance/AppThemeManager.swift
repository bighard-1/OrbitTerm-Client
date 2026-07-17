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
        selectedTheme = theme
        defaults.set(theme.rawValue, forKey: Self.themeStorageKey)
    }

    func selectMode(_ mode: AppearanceMode) {
        appearanceMode = mode
        defaults.set(mode.rawValue, forKey: Self.modeStorageKey)
    }
}
