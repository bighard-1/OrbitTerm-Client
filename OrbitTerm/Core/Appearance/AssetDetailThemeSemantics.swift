import SwiftUI

/// Presentation-only roles for the asset editor's connection test chrome.
/// The caller supplies typed booleans; no user-visible status text is parsed.
enum AssetConnectionTestPresentation {
    case idle
    case testing
    case verified

    static func resolve(isTesting: Bool, isVerified: Bool) -> Self {
        if isTesting { return .testing }
        return isVerified ? .verified : .idle
    }

    var securityKind: SecurityStatusKind? {
        switch self {
        case .testing: .information
        case .verified: .success
        case .idle: nil
        }
    }

    func themeColor(in security: SecuritySemanticPalette, fallback: AppThemePalette) -> ThemeColor {
        guard let securityKind else { return fallback.textSecondary }
        return security.presentation(for: securityKind).color
    }
}
