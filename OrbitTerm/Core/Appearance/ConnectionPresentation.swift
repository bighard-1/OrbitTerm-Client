import SwiftUI

enum ConnectionPresentationPhase: Equatable {
    case idle, connecting, awaitingHostKeyDecision, openingTerminal, connected, disconnected, blocked, failed, cancelled
}

enum ConnectionSemanticRole { case connected, connecting, disconnected, warning, danger, blocked }

struct ConnectionPresentation: Equatable {
    let phase: ConnectionPresentationPhase
    let label: String
    let systemImage: String
    let semanticRole: ConnectionSemanticRole
    let showsProgress: Bool
}

struct ConnectionPresentationInput: Equatable {
    let hasVerifiedLease: Bool
    let hasTerminalChannel: Bool
    let isConnected: Bool
    let isAwaitingHostKeyDecision: Bool
    let explicitPhase: ConnectionPresentationPhase?

}

enum ConnectionPresentationMapper {
    static func map(_ input: ConnectionPresentationInput) -> ConnectionPresentation {
        if input.isAwaitingHostKeyDecision { return .init(phase: .awaitingHostKeyDecision, label: "等待确认主机身份", systemImage: "shield.lefthalf.filled", semanticRole: .warning, showsProgress: false) }
        switch input.explicitPhase {
        case .awaitingHostKeyDecision?: return .init(phase: .awaitingHostKeyDecision, label: "等待确认主机身份", systemImage: "shield.lefthalf.filled", semanticRole: .warning, showsProgress: false)
        case .blocked?: return .init(phase: .blocked, label: "服务器身份已阻断", systemImage: "xmark.shield.fill", semanticRole: .blocked, showsProgress: false)
        case .failed?: return .init(phase: .failed, label: "连接失败", systemImage: "exclamationmark.triangle.fill", semanticRole: .danger, showsProgress: false)
        case .cancelled?: return .init(phase: .cancelled, label: "连接已取消", systemImage: "xmark.circle", semanticRole: .disconnected, showsProgress: false)
        case .disconnected?: return .init(phase: .disconnected, label: "连接已断开", systemImage: "network.slash", semanticRole: .disconnected, showsProgress: false)
        case .connecting?: return .init(phase: .connecting, label: "正在连接", systemImage: "arrow.triangle.2.circlepath", semanticRole: .connecting, showsProgress: true)
        default: break
        }
        if input.hasVerifiedLease && input.hasTerminalChannel && input.isConnected { return .init(phase: .connected, label: "已连接并验证", systemImage: "checkmark.shield.fill", semanticRole: .connected, showsProgress: false) }
        if input.hasVerifiedLease && !input.hasTerminalChannel { return .init(phase: .openingTerminal, label: "安全连接已建立，正在打开终端", systemImage: "terminal", semanticRole: .connecting, showsProgress: true) }
        switch input.explicitPhase {
        case .blocked?: return .init(phase: .blocked, label: "服务器身份已阻断", systemImage: "xmark.shield.fill", semanticRole: .blocked, showsProgress: false)
        case .failed?: return .init(phase: .failed, label: "连接失败", systemImage: "exclamationmark.triangle.fill", semanticRole: .danger, showsProgress: false)
        case .cancelled?: return .init(phase: .cancelled, label: "连接已取消", systemImage: "xmark.circle", semanticRole: .disconnected, showsProgress: false)
        case .disconnected?: return .init(phase: .disconnected, label: "连接已断开", systemImage: "network.slash", semanticRole: .disconnected, showsProgress: false)
        case .connecting?: return .init(phase: .connecting, label: "正在连接", systemImage: "arrow.triangle.2.circlepath", semanticRole: .connecting, showsProgress: true)
        default: return .init(phase: .idle, label: "未连接", systemImage: "circle", semanticRole: .disconnected, showsProgress: false)
        }
    }

}

struct ConnectionStatusBadge: View {
    let presentation: ConnectionPresentation
    @Environment(\.securitySemanticPalette) private var semantic
    private var color: Color { switch presentation.semanticRole { case .connected: semantic.connectionConnected.color; case .connecting: semantic.connectionConnecting.color; case .disconnected: semantic.connectionDisconnected.color; case .warning: semantic.warning.color; case .danger: semantic.danger.color; case .blocked: semantic.connectionBlocked.color } }
    var body: some View { Image(systemName: presentation.systemImage).foregroundStyle(color).accessibilityLabel(presentation.label).accessibilityValue(presentation.label) }
}

struct ConnectionStatusRow: View {
    let presentation: ConnectionPresentation
    var body: some View { HStack(spacing: 6) { ConnectionStatusBadge(presentation: presentation); Text(presentation.label) }.accessibilityElement(children: .combine).accessibilityLabel(presentation.label) }
}

struct ConnectionProgressBanner: View {
    let presentation: ConnectionPresentation
    var body: some View { ConnectionStatusRow(presentation: presentation).overlay(alignment: .trailing) { if presentation.showsProgress { ProgressView().controlSize(.small).accessibilityHidden(true) } } }
}
