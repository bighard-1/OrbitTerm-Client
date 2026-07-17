import SwiftUI

/// Pure presentation decisions shared by themed SwiftUI chrome.
/// This intentionally accepts accessibility settings and never interprets business text.
enum AppAccessibilityPresentation {
    static func borderWidth(for contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? 2 : 1
    }

    static func usesOpaqueSurface(reduceTransparency: Bool) -> Bool {
        reduceTransparency
    }

    static func usesDecorativeMotion(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    static func needsNonColorStatusAffordance(differentiateWithoutColor: Bool) -> Bool {
        differentiateWithoutColor
    }
}
