import SwiftUI

/// Presentation-only Docker states derived from reliable, non-localized values.
/// More detailed lifecycle or health states must not be inferred from status text.
enum DockerContainerPresentationState: Equatable {
    case running
    case stopped

    var securityKind: SecurityStatusKind? {
        switch self {
        case .running: .success
        case .stopped: nil
        }
    }

    var symbol: String {
        switch self {
        case .running: "play.circle.fill"
        case .stopped: "stop.circle"
        }
    }

    var label: String {
        switch self {
        case .running: "运行中"
        case .stopped: "已停止"
        }
    }

    func themeColor(in security: SecuritySemanticPalette, fallback: AppThemePalette) -> ThemeColor {
        guard let securityKind else { return fallback.textSecondary }
        return security.presentation(for: securityKind).color
    }

    static func resolve(isRunning: Bool) -> Self { isRunning ? .running : .stopped }
}

enum DockerConnectionPresentationState: Equatable {
    case connecting
    case unavailable
    case connected
    case disconnected

    var securityKind: SecurityStatusKind? {
        switch self {
        case .connecting: .information
        case .unavailable: .warning
        case .connected: .success
        case .disconnected: nil
        }
    }

    func themeColor(in security: SecuritySemanticPalette, fallback: AppThemePalette) -> ThemeColor {
        guard let securityKind else { return fallback.textSecondary }
        return security.presentation(for: securityKind).color
    }
}
