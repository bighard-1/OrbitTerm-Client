import SwiftUI

private struct AppThemePaletteKey: EnvironmentKey { static let defaultValue = AppThemePalette.fallback }
private struct SecuritySemanticPaletteKey: EnvironmentKey { static let defaultValue = SecuritySemanticPalette() }

extension EnvironmentValues {
    var appThemePalette: AppThemePalette { get { self[AppThemePaletteKey.self] } set { self[AppThemePaletteKey.self] = newValue } }
    var securitySemanticPalette: SecuritySemanticPalette { get { self[SecuritySemanticPaletteKey.self] } set { self[SecuritySemanticPaletteKey.self] = newValue } }
}

private struct AppThemeInjection: ViewModifier {
    @EnvironmentObject private var themeManager: AppThemeManager
    @Environment(\.colorScheme) private var systemColorScheme
    func body(content: Content) -> some View {
        content
            .environment(\.appThemePalette, themeManager.palette(for: systemColorScheme))
            .environment(\.securitySemanticPalette, SecuritySemanticPalette())
            .preferredColorScheme(themeManager.preferredColorScheme)
    }
}

extension View { func injectAppTheme() -> some View { modifier(AppThemeInjection()) } }
