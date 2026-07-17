import Foundation

enum HostKeyPresentationSnapshot: Equatable {
    enum BlockReason: Equatable { case changed, revoked, unsupported }
    enum Failure: Equatable { case storeSave, authentication, network, timeout, operation }
    case none, awaitingDecision, blocked(BlockReason), failed(Failure), cancelled

    static func from(state: HostKeyTrustState) -> Self {
        switch state {
        case .awaitingUserDecision: .awaitingDecision
        case let .blocked(_, payload): .blocked(HostKeyBlockedPresentation(payload: payload).severity.snapshotReason)
        case let .failed(_, failure): from(failure: failure)
        case .cancelled: .cancelled
        default: .none
        }
    }
    static func from(outcome: CheckedTerminalConnectionOutcome) -> Self {
        switch outcome {
        case .awaitingUserDecision: .awaitingDecision
        case let .blocked(payload): .blocked(HostKeyBlockedPresentation(payload: payload).severity.snapshotReason)
        case let .failed(failure): from(failure: failure)
        case .terminalOpenFailed: .failed(.operation)
        case .cancelled: .cancelled
        default: .none
        }
    }
    private static func from(failure: HostKeyTrustFailure) -> Self {
        switch failure { case .storeSave: .failed(.storeSave); case .authentication: .failed(.authentication); case .network: .failed(.network); case .timeout: .failed(.timeout); default: .failed(.operation) }
    }
}

private extension HostKeyBlockedPresentation.Severity {
    var snapshotReason: HostKeyPresentationSnapshot.BlockReason { switch self { case .changed: .changed; case .revoked: .revoked; case .unsupported: .unsupported } }
}
