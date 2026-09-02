import Foundation

struct ConnectionPresentationSnapshot: Equatable {
    let hasVerifiedSessionLease: Bool; let hasTerminalChannel: Bool; let isSessionUsable: Bool
    let isConnectOperationInProgress: Bool; let wasConnectionLost: Bool; let hostKey: HostKeyPresentationSnapshot
}
enum ConnectionPresentationAdapter {
    /// UI callers pass only an instantaneous checked-SSH value snapshot; no session or global state is retained.
    static func terminal(
        hasVerifiedSessionLease: Bool,
        hasTerminalChannel: Bool,
        isSessionUsable: Bool,
        requiresVerifiedLease: Bool,
        phase: ConnectionPresentationPhase
    ) -> ConnectionPresentation {
        ConnectionPresentationMapper.map(
            .init(
                hasVerifiedLease: hasVerifiedSessionLease,
                hasTerminalChannel: hasTerminalChannel,
                isConnected: isSessionUsable,
                requiresVerifiedLease: requiresVerifiedLease,
                isAwaitingHostKeyDecision: phase == .awaitingHostKeyDecision,
                explicitPhase: phase
            )
        )
    }

    static func checkedSSH(hasVerifiedSessionLease: Bool, hasTerminalChannel: Bool, isSessionUsable: Bool) -> ConnectionPresentation {
        terminal(
            hasVerifiedSessionLease: hasVerifiedSessionLease,
            hasTerminalChannel: hasTerminalChannel,
            isSessionUsable: isSessionUsable,
            requiresVerifiedLease: true,
            phase: isSessionUsable ? .connected : .idle
        )
    }
#if os(macOS)
    static func remoteDesktop(phase: RemoteDesktopSessionPhase) -> ConnectionPresentation {
        switch phase {
        case .starting, .authenticating, .reconnecting:
            .init(
                phase: .connecting,
                label: "正在连接远程桌面",
                systemImage: "arrow.triangle.2.circlepath",
                semanticRole: .connecting,
                showsProgress: true
            )
        case .awaitingUserDecision:
            .init(
                phase: .awaitingHostKeyDecision,
                label: "等待确认远程桌面证书",
                systemImage: "checkmark.shield",
                semanticRole: .warning,
                showsProgress: false
            )
        case .connected:
            .init(
                phase: .connected,
                label: "远程桌面已连接",
                systemImage: "checkmark.shield.fill",
                semanticRole: .connected,
                showsProgress: false
            )
        case .disconnected:
            .init(
                phase: .disconnected,
                label: "远程桌面已断开",
                systemImage: "network.slash",
                semanticRole: .disconnected,
                showsProgress: false
            )
        case .failed:
            .init(
                phase: .failed,
                label: "远程桌面连接失败",
                systemImage: "exclamationmark.triangle.fill",
                semanticRole: .danger,
                showsProgress: false
            )
        case .closed:
            .init(
                phase: .idle,
                label: "未连接",
                systemImage: "circle",
                semanticRole: .disconnected,
                showsProgress: false
            )
        }
    }
#endif
    static func input(_ snapshot: ConnectionPresentationSnapshot) -> ConnectionPresentationInput {
        let phase: ConnectionPresentationPhase?
        switch snapshot.hostKey {
        case .blocked: phase = .blocked
        case .failed: phase = .failed
        case .awaitingDecision: phase = .awaitingHostKeyDecision
        case .cancelled: phase = .cancelled
        case .none where snapshot.isConnectOperationInProgress: phase = .connecting
        case .none where snapshot.wasConnectionLost: phase = .disconnected
        default: phase = nil
        }
        return .init(hasVerifiedLease: snapshot.hasVerifiedSessionLease, hasTerminalChannel: snapshot.hasTerminalChannel, isConnected: snapshot.isSessionUsable, requiresVerifiedLease: true, isAwaitingHostKeyDecision: false, explicitPhase: phase)
    }
}
