import Foundation

struct ConnectionPresentationSnapshot: Equatable {
    let hasVerifiedSessionLease: Bool; let hasTerminalChannel: Bool; let isSessionUsable: Bool
    let isConnectOperationInProgress: Bool; let wasConnectionLost: Bool; let hostKey: HostKeyPresentationSnapshot
}
enum ConnectionPresentationAdapter {
    /// UI callers pass only an instantaneous checked-SSH value snapshot; no session or global state is retained.
    static func checkedSSH(hasVerifiedSessionLease: Bool, hasTerminalChannel: Bool, isSessionUsable: Bool) -> ConnectionPresentation {
        ConnectionPresentationMapper.map(input(.init(hasVerifiedSessionLease: hasVerifiedSessionLease, hasTerminalChannel: hasTerminalChannel, isSessionUsable: isSessionUsable, isConnectOperationInProgress: false, wasConnectionLost: false, hostKey: .none)))
    }
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
        return .init(hasVerifiedLease: snapshot.hasVerifiedSessionLease, hasTerminalChannel: snapshot.hasTerminalChannel, isConnected: snapshot.isSessionUsable, isAwaitingHostKeyDecision: false, explicitPhase: phase)
    }
}
