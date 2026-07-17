import SwiftUI

/// Presentation-only semantic levels. `cpuZone` is an existing MonitorPoint
/// threshold result; this mapping never inspects user-visible status text.
enum MonitorMetricPresentationLevel: Equatable {
    case normal
    case warning
    case critical
    case unavailable

    static func existingCPUZone(_ zone: String) -> Self {
        switch zone {
        case "warning": .warning
        case "alert": .critical
        default: .normal
        }
    }

    var securityKind: SecurityStatusKind? {
        switch self {
        case .normal: nil
        case .warning: .warning
        case .critical: .danger
        case .unavailable: nil
        }
    }

    func themeColor(in security: SecuritySemanticPalette, fallback: AppThemePalette) -> ThemeColor {
        switch self {
        case .normal: fallback.accentPrimary
        case .warning: security.warning
        case .critical: security.danger
        case .unavailable: fallback.textSecondary
        }
    }
}
