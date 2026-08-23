import SwiftUI

struct ThemeColor: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let opacity: Double

    init(_ red: Double, _ green: Double, _ blue: Double, opacity: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.opacity = opacity
    }

    var color: Color { Color(red: red, green: green, blue: blue, opacity: opacity) }

    var relativeLuminance: Double {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrastRatio(with other: ThemeColor) -> Double {
        (max(relativeLuminance, other.relativeLuminance) + 0.05) / (min(relativeLuminance, other.relativeLuminance) + 0.05)
    }
}

struct AppThemePalette: Hashable {
    let pageBackground: ThemeColor
    let backgroundGlowPrimary: ThemeColor
    let backgroundGlowSecondary: ThemeColor
    let surfaceGlass: ThemeColor
    let surfaceGlassStrong: ThemeColor
    let surfaceReadable: ThemeColor
    let surfaceCritical: ThemeColor
    let surfaceInput: ThemeColor
    let textPrimary: ThemeColor
    let textSecondary: ThemeColor
    let textDisabled: ThemeColor
    let textOnAccent: ThemeColor
    let accentPrimary: ThemeColor
    let accentSecondary: ThemeColor
    let focusRing: ThemeColor
    let borderGlass: ThemeColor
    let divider: ThemeColor

    var previewColors: [ThemeColor] { [accentPrimary, accentSecondary, backgroundGlowPrimary] }

    static func make(theme: AppThemeID, colorScheme: ColorScheme) -> AppThemePalette {
        let isDark = colorScheme == .dark
        let decorations: (ThemeColor, ThemeColor, ThemeColor, ThemeColor) = {
            switch theme {
            case .skyCandy: (.init(0.07, 0.38, 0.76), .init(0.22, 0.64, 0.87), .init(0.38, 0.73, 1, opacity: 0.32), .init(0.76, 0.45, 0.95, opacity: 0.22))
            case .emeraldFlow: (.init(0.03, 0.40, 0.30), .init(0.07, 0.58, 0.48), .init(0.12, 0.75, 0.56, opacity: 0.28), .init(0.10, 0.50, 0.82, opacity: 0.18))
            case .peachDawn: (.init(0.61, 0.20, 0.20), .init(0.83, 0.38, 0.28), .init(1, 0.55, 0.40, opacity: 0.28), .init(0.95, 0.30, 0.47, opacity: 0.18))
            case .lavenderMist: (.init(0.38, 0.22, 0.58), .init(0.53, 0.37, 0.73), .init(0.66, 0.49, 0.93, opacity: 0.27), .init(0.40, 0.62, 0.96, opacity: 0.17))
            case .glacierMint: (.init(0.02, 0.39, 0.45), .init(0.08, 0.56, 0.61), .init(0.24, 0.78, 0.76, opacity: 0.26), .init(0.36, 0.64, 0.96, opacity: 0.16))
            }
        }()

        func blended(
            _ red: Double,
            _ green: Double,
            _ blue: Double,
            with tint: ThemeColor,
            amount: Double,
            opacity: Double = 1
        ) -> ThemeColor {
            let clampedAmount = min(max(amount, 0), 1)
            return ThemeColor(
                red * (1 - clampedAmount) + tint.red * clampedAmount,
                green * (1 - clampedAmount) + tint.green * clampedAmount,
                blue * (1 - clampedAmount) + tint.blue * clampedAmount,
                opacity: opacity
            )
        }

#if os(macOS)
        let darkValues = (0.18, 0.18, 0.22, 0.18, 0.15, 0.34, 0.38, 0.30, 0.28)
        let lightValues = (0.18, 0.10, 0.15, 0.12, 0.10, 0.32, 0.32, 0.28, 0.24)
#else
        // Mobile clients keep their established visual density. The stronger
        // desktop hierarchy is deliberately scoped to macOS.
        let darkValues = (0.11, 0.12, 0.15, 0.12, 0.08, 0.28, 0.28, 0.24, 0.20)
        let lightValues = (0.08, 0.05, 0.08, 0.06, 0.04, 0.26, 0.20, 0.20, 0.16)
#endif

        if isDark {
            return .init(
                pageBackground: blended(0.045, 0.065, 0.10, with: decorations.0, amount: darkValues.0),
                backgroundGlowPrimary: decorations.2,
                backgroundGlowSecondary: decorations.3,
                surfaceGlass: blended(0.10, 0.13, 0.19, with: decorations.0, amount: darkValues.1),
                surfaceGlassStrong: blended(0.13, 0.16, 0.23, with: decorations.0, amount: darkValues.2),
                surfaceReadable: blended(0.12, 0.15, 0.21, with: decorations.0, amount: darkValues.3),
                surfaceCritical: .init(0.25, 0.09, 0.10),
                surfaceInput: blended(0.08, 0.11, 0.16, with: decorations.0, amount: darkValues.4),
                textPrimary: .init(0.96, 0.97, 0.99),
                textSecondary: .init(0.79, 0.83, 0.89),
                textDisabled: .init(0.61, 0.66, 0.74),
                textOnAccent: .init(1, 1, 1),
                accentPrimary: decorations.0,
                accentSecondary: decorations.1,
                focusRing: decorations.1,
                borderGlass: blended(0.78, 0.84, 0.95, with: decorations.1, amount: darkValues.5, opacity: darkValues.6),
                divider: blended(0.78, 0.84, 0.95, with: decorations.1, amount: darkValues.7, opacity: darkValues.8)
            )
        }
        return .init(
            pageBackground: blended(0.94, 0.96, 0.99, with: decorations.0, amount: lightValues.0),
            backgroundGlowPrimary: decorations.2,
            backgroundGlowSecondary: decorations.3,
            surfaceGlass: blended(1, 1, 1, with: decorations.0, amount: lightValues.1),
            surfaceGlassStrong: blended(1, 1, 1, with: decorations.0, amount: lightValues.2),
            surfaceReadable: blended(1, 1, 1, with: decorations.0, amount: lightValues.3),
            surfaceCritical: .init(1, 0.94, 0.94),
            surfaceInput: blended(0.98, 0.99, 1, with: decorations.0, amount: lightValues.4),
            textPrimary: .init(0.07, 0.10, 0.16),
            textSecondary: .init(0.26, 0.31, 0.40),
            textDisabled: .init(0.39, 0.44, 0.53),
            textOnAccent: .init(1, 1, 1),
            accentPrimary: decorations.0,
            accentSecondary: decorations.1,
            focusRing: decorations.1,
            borderGlass: blended(0.16, 0.22, 0.34, with: decorations.0, amount: lightValues.5, opacity: lightValues.6),
            divider: blended(0.16, 0.22, 0.34, with: decorations.0, amount: lightValues.7, opacity: lightValues.8)
        )
    }

    static let fallback = make(theme: .defaultTheme, colorScheme: .light)
}
