import Foundation

struct VerifiedWorkspaceSession: Hashable, Sendable {
    let workspaceID: UUID
    let baseSessionID: BaseSessionID
    let terminalChannelID: TerminalChannelID?
}

enum CheckedTerminalConnectionOutcome: Hashable, Sendable {
    case pending
    case awaitingUserDecision
    case connected(VerifiedWorkspaceSession)
    case terminalOpenFailed(VerifiedWorkspaceSession, CheckedFFIClientError)
    case blocked(HostKeyBlockedPayload)
    case failed(HostKeyTrustFailure)
    case cancelled
}

@MainActor
final class CheckedTerminalConnectionOrchestrator {
    let coordinator: HostKeyTrustCoordinator

    private let workspaceID: UUID
    private let client: any CheckedFFIClient
    private let cols: UInt32
    private let rows: UInt32

    init(
        workspaceID: UUID,
        client: any CheckedFFIClient,
        cols: UInt32 = 120,
        rows: UInt32 = 36,
        operationTimeoutNanoseconds: UInt64 = 20_000_000_000
    ) {
        self.workspaceID = workspaceID
        self.client = client
        self.cols = cols
        self.rows = rows
        coordinator = HostKeyTrustCoordinator(
            client: client,
            operationTimeoutNanoseconds: operationTimeoutNanoseconds
        )
    }

    func begin(input: CheckedConnectInput) async -> CheckedTerminalConnectionOutcome {
        await coordinator.begin(input: input)
        return await consumeCoordinatorState()
    }

    func trustCurrentChallenge() async -> CheckedTerminalConnectionOutcome {
        await coordinator.trustCurrentChallenge()
        return await consumeCoordinatorState()
    }

    func retrySave() async -> CheckedTerminalConnectionOutcome {
        await coordinator.retrySave()
        return await consumeCoordinatorState()
    }

    func cancel() -> CheckedTerminalConnectionOutcome {
        coordinator.cancel()
        return .cancelled
    }

    func close() {
        coordinator.close()
    }

    private func consumeCoordinatorState() async -> CheckedTerminalConnectionOutcome {
        switch coordinator.state {
        case let .connected(_, baseSessionID):
            return await openTerminal(baseSessionID: baseSessionID)
        case .awaitingUserDecision:
            return .awaitingUserDecision
        case .persisting, .connecting, .reconnecting:
            return .pending
        case let .blocked(_, payload):
            return .blocked(payload)
        case let .failed(_, failure):
            return .failed(failure)
        case .cancelled:
            return .cancelled
        case .idle:
            return .failed(.protocolViolation)
        }
    }

    private func openTerminal(baseSessionID: BaseSessionID) async -> CheckedTerminalConnectionOutcome {
        guard (1 ... 1_000).contains(cols), (1 ... 1_000).contains(rows) else {
            return .terminalOpenFailed(
                VerifiedWorkspaceSession(
                    workspaceID: workspaceID,
                    baseSessionID: baseSessionID,
                    terminalChannelID: nil
                ),
                .invalidInput
            )
        }
        let requestID = HostKeyRequestID()
        do {
            let response = try await client.openTerminalChecked(
                requestID: requestID,
                baseSessionID: baseSessionID,
                cols: cols,
                rows: rows
            )
            guard response.requestID == requestID,
                  response.value.baseSessionID == baseSessionID else {
                return .terminalOpenFailed(
                    VerifiedWorkspaceSession(
                        workspaceID: workspaceID,
                        baseSessionID: baseSessionID,
                        terminalChannelID: nil
                    ),
                    .requestIDMismatch
                )
            }
            return .connected(
                VerifiedWorkspaceSession(
                    workspaceID: workspaceID,
                    baseSessionID: baseSessionID,
                    terminalChannelID: response.value.terminalChannelID
                )
            )
        } catch let error as CheckedFFIClientError {
            return .terminalOpenFailed(
                VerifiedWorkspaceSession(
                    workspaceID: workspaceID,
                    baseSessionID: baseSessionID,
                    terminalChannelID: nil
                ),
                error
            )
        } catch {
            return .terminalOpenFailed(
                VerifiedWorkspaceSession(
                    workspaceID: workspaceID,
                    baseSessionID: baseSessionID,
                    terminalChannelID: nil
                ),
                .protocolViolation
            )
        }
    }
}

@MainActor
final class CheckedHostKeyPresentationRoute: Identifiable {
    let id: UUID
    let workspaceID: UUID
    let orchestrator: CheckedTerminalConnectionOrchestrator

    init(workspaceID: UUID, orchestrator: CheckedTerminalConnectionOrchestrator) {
        id = workspaceID
        self.workspaceID = workspaceID
        self.orchestrator = orchestrator
    }

    var coordinator: HostKeyTrustCoordinator { orchestrator.coordinator }
}
