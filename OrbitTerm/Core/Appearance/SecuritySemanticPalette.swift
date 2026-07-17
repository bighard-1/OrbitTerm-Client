import SwiftUI

enum SecurityStatusKind { case success, warning, danger, information }

struct SecurityStatusPresentation: Hashable {
    let color: ThemeColor
    let symbol: String
    let label: String
}

struct SecuritySemanticPalette: Hashable {
    let success = ThemeColor(0.02, 0.42, 0.25)
    let warning = ThemeColor(0.61, 0.29, 0.02)
    let danger = ThemeColor(0.70, 0.10, 0.08)
    let information = ThemeColor(0.08, 0.31, 0.70)
    let connectionConnected = ThemeColor(0.02, 0.42, 0.25)
    let connectionConnecting = ThemeColor(0.08, 0.31, 0.70)
    let connectionReconnecting = ThemeColor(0.61, 0.29, 0.02)
    let connectionDisconnected = ThemeColor(0.34, 0.38, 0.45)
    let connectionBlocked = ThemeColor(0.70, 0.10, 0.08)

    func presentation(for kind: SecurityStatusKind) -> SecurityStatusPresentation {
        switch kind {
        case .success: .init(color: success, symbol: "checkmark.circle.fill", label: "成功")
        case .warning: .init(color: warning, symbol: "exclamationmark.triangle.fill", label: "注意")
        case .danger: .init(color: danger, symbol: "xmark.octagon.fill", label: "错误")
        case .information: .init(color: information, symbol: "info.circle.fill", label: "提示")
        }
    }
}
