import Foundation

/// Keeps terminal readability checks separate from AppTheme. ANSI index 0 is
/// intentionally not assessed here because it represents a terminal's black
/// color, not its default text color.
enum TerminalThemeReadability {
    static func defaultTextContrastRatio(for theme: TerminalTheme) -> Double {
        contrastRatio(foreground: theme.foreground, background: theme.background)
    }

    static func hasReadableDefaultText(_ theme: TerminalTheme, minimumRatio: Double = 4.5) -> Bool {
        defaultTextContrastRatio(for: theme) >= minimumRatio
    }

    private static func contrastRatio(foreground: TerminalRGB, background: TerminalRGB) -> Double {
        let lighter = max(relativeLuminance(foreground), relativeLuminance(background))
        let darker = min(relativeLuminance(foreground), relativeLuminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ color: TerminalRGB) -> Double {
        let components = [color.r, color.g, color.b].map { component -> Double in
            let normalized = Double(component) / 255.0
            return normalized <= 0.04045
                ? normalized / 12.92
                : pow((normalized + 0.055) / 1.055, 2.4)
        }
        return (0.2126 * components[0]) + (0.7152 * components[1]) + (0.0722 * components[2])
    }
}
