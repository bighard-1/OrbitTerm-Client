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
#if os(macOS)
        return desktopPalette(theme: theme, isDark: isDark)
#else
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
#endif
    }

#if os(macOS)
    private static func desktopPalette(theme: AppThemeID, isDark: Bool) -> AppThemePalette {
        typealias Core = (
            accent: ThemeColor,
            workbench: ThemeColor,
            chrome: ThemeColor,
            panel: ThemeColor,
            metric: ThemeColor,
            stroke: ThemeColor,
            dialog: ThemeColor,
            accentSoft: ThemeColor
        )

        func rgb(_ red: Int, _ green: Int, _ blue: Int, opacity: Double = 1) -> ThemeColor {
            ThemeColor(
                Double(red) / 255,
                Double(green) / 255,
                Double(blue) / 255,
                opacity: opacity
            )
        }

        let core: Core = switch (theme, isDark) {
        case (.skyCandy, false): (
            rgb(18, 97, 194), rgb(226, 239, 252), rgb(207, 228, 249), rgb(241, 248, 255),
            rgb(218, 235, 251), rgb(147, 185, 222), rgb(244, 250, 255), rgb(202, 225, 248)
        )
        case (.skyCandy, true): (
            rgb(108, 182, 255), rgb(10, 22, 31), rgb(14, 34, 47), rgb(20, 42, 56),
            rgb(26, 51, 66), rgb(49, 81, 101), rgb(24, 47, 61), rgb(28, 59, 78)
        )
        case (.peachDawn, false): (
            rgb(156, 51, 51), rgb(252, 231, 219), rgb(247, 214, 197), rgb(255, 244, 237),
            rgb(249, 222, 208), rgb(214, 164, 141), rgb(255, 246, 240), rgb(244, 211, 196)
        )
        case (.peachDawn, true): (
            rgb(242, 160, 122), rgb(27, 19, 16), rgb(42, 28, 23), rgb(51, 35, 29),
            rgb(61, 43, 35), rgb(100, 67, 54), rgb(55, 37, 30), rgb(70, 45, 36)
        )
        case (.lavenderMist, false): (
            rgb(97, 56, 148), rgb(237, 229, 248), rgb(224, 211, 243), rgb(249, 244, 254),
            rgb(229, 218, 246), rgb(184, 159, 215), rgb(250, 246, 254), rgb(220, 204, 242)
        )
        case (.lavenderMist, true): (
            rgb(180, 154, 235), rgb(23, 18, 32), rgb(35, 27, 49), rgb(44, 35, 62),
            rgb(53, 43, 73), rgb(84, 70, 108), rgb(48, 38, 66), rgb(62, 47, 85)
        )
        case (.glacierMint, false): (
            rgb(5, 99, 115), rgb(224, 241, 244), rgb(205, 231, 235), rgb(240, 249, 250),
            rgb(214, 236, 239), rgb(143, 190, 197), rgb(243, 250, 251), rgb(198, 230, 234)
        )
        case (.glacierMint, true): (
            rgb(98, 196, 210), rgb(10, 23, 26), rgb(15, 37, 42), rgb(22, 47, 53),
            rgb(28, 57, 64), rgb(52, 88, 95), rgb(26, 52, 58), rgb(30, 67, 74)
        )
        case (.emeraldFlow, true): (
            rgb(95, 208, 154), rgb(11, 24, 18), rgb(16, 38, 27), rgb(23, 47, 35),
            rgb(29, 57, 42), rgb(53, 91, 69), rgb(27, 52, 39), rgb(31, 69, 49)
        )
        default: (
            rgb(8, 102, 77), rgb(226, 242, 233), rgb(208, 232, 218), rgb(242, 250, 246),
            rgb(217, 238, 225), rgb(147, 192, 166), rgb(245, 251, 247), rgb(202, 233, 216)
        )
        }

        let textPrimary = isDark ? rgb(245, 247, 250) : rgb(18, 26, 41)
        let textSecondary = isDark ? rgb(201, 212, 227) : rgb(66, 79, 102)
        let textDisabled = isDark ? rgb(156, 168, 189) : rgb(99, 112, 135)
        return .init(
            pageBackground: core.workbench,
            backgroundGlowPrimary: rgb(
                Int((core.accent.red * 255).rounded()),
                Int((core.accent.green * 255).rounded()),
                Int((core.accent.blue * 255).rounded()),
                opacity: 0.18
            ),
            backgroundGlowSecondary: rgb(
                Int((core.accentSoft.red * 255).rounded()),
                Int((core.accentSoft.green * 255).rounded()),
                Int((core.accentSoft.blue * 255).rounded()),
                opacity: 0.14
            ),
            surfaceGlass: core.chrome,
            surfaceGlassStrong: core.panel,
            surfaceReadable: core.dialog,
            surfaceCritical: isDark ? rgb(64, 28, 32) : rgb(255, 240, 240),
            surfaceInput: core.metric,
            textPrimary: textPrimary,
            textSecondary: textSecondary,
            textDisabled: textDisabled,
            textOnAccent: isDark ? rgb(11, 18, 15) : rgb(255, 255, 255),
            accentPrimary: core.accent,
            accentSecondary: core.accentSoft,
            focusRing: core.accent,
            borderGlass: core.stroke,
            divider: core.stroke
        )
    }
#endif

    static let fallback = make(theme: .defaultTheme, colorScheme: .light)
}
