import SwiftUI

/// Presentation-only roles for SFTP chrome. Callers must supply the role from
/// typed transfer state; this type deliberately never parses user-visible text.
enum SFTPTransferSemanticRole: CaseIterable {
    case inProgress
    case success
    case warning
    case failure
    case cancelled

    static func transferState(isDone: Bool, progress: Double) -> Self {
        guard isDone else { return .inProgress }
        return progress >= 1 ? .success : .failure
    }

    var securityKind: SecurityStatusKind? {
        switch self {
        case .inProgress:
            .information
        case .success:
            .success
        case .warning:
            .warning
        case .failure:
            .danger
        case .cancelled:
            nil
        }
    }

    func themeColor(in palette: SecuritySemanticPalette, fallback: AppThemePalette) -> ThemeColor {
        guard let securityKind else { return fallback.textSecondary }
        return palette.presentation(for: securityKind).color
    }
}
