import Combine
import Foundation

struct HostKeyFlowID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String { "flow:\(rawValue.uuidString.lowercased())" }
}

enum HostKeyTrustFailure: Hashable, Sendable {
    case authentication(CheckedFFIErrorPayload)
    case network(CheckedFFIErrorPayload)
    case timeout(CheckedFFIErrorPayload?)
    case store(CheckedFFIErrorPayload)
    case storeSave(HostKeyChallengePayload, CheckedFFIErrorPayload)
    case operation(CheckedFFIErrorPayload)
    case client(CheckedFFIClientError)
    case protocolViolation
}

enum HostKeyTrustState: Hashable, Sendable {
    case idle
    case connecting(HostKeyFlowID, HostKeyRequestID)
    case awaitingUserDecision(HostKeyFlowID, HostKeyChallengePayload)
    case persisting(HostKeyFlowID, HostKeyChallengePayload, HostKeyRequestID)
    case reconnecting(HostKeyFlowID, HostKeyRequestID)
    case connected(HostKeyFlowID, BaseSessionID)
    case blocked(HostKeyFlowID, HostKeyBlockedPayload)
    case failed(HostKeyFlowID, HostKeyTrustFailure)
    case cancelled(HostKeyFlowID)
}

@MainActor
final class HostKeyTrustCoordinator: ObservableObject {
    @Published private(set) var state: HostKeyTrustState = .idle

    private let client: any CheckedFFIClient
    private let operationTimeoutNanoseconds: UInt64
    private var context: FlowContext?

    init(
        client: any CheckedFFIClient,
        operationTimeoutNanoseconds: UInt64 = 20_000_000_000
    ) {
        self.client = client
        self.operationTimeoutNanoseconds = operationTimeoutNanoseconds
    }

    @discardableResult
    func begin(input: CheckedConnectInput) async -> HostKeyFlowID {
        let flowID = HostKeyFlowID()
        context = FlowContext(flowID: flowID, input: input)
        await connect(flowID: flowID, phase: .initial)
        return flowID
    }

    func trustCurrentChallenge(comment: String? = nil) async {
        guard let context,
              case let .awaitingUserDecision(flowID, challenge) = state,
              flowID == context.flowID else {
            return
        }
        guard challenge.expiresAtUnix > UInt64(Date().timeIntervalSince1970) else {
            state = .failed(flowID, .protocolViolation)
            return
        }
        await persist(challenge: challenge, context: context, comment: comment)
    }

    func retrySave(comment: String? = nil) async {
        guard let context,
              case let .failed(flowID, .storeSave(challenge, _)) = state,
              flowID == context.flowID else {
            return
        }
        await persist(challenge: challenge, context: context, comment: comment)
    }

    func cancel() {
        guard let context else { return }
        state = .cancelled(context.flowID)
        self.context = nil
    }

    func close() {
        context = nil
        state = .idle
    }

    private enum ConnectPhase {
        case initial
        case reconnect
    }

    private func connect(flowID: HostKeyFlowID, phase: ConnectPhase) async {
        guard var active = context, active.flowID == flowID else { return }
        let requestID = HostKeyRequestID()
        active.pendingRequestID = requestID
        context = active
        state = phase == .initial
            ? .connecting(flowID, requestID)
            : .reconnecting(flowID, requestID)

        do {
            let client = self.client
            let input = active.input
            let response = try await withTimeout {
                try await client.connectChecked(requestID: requestID, input: input)
            }
            guard isCurrent(flowID: flowID, requestID: requestID),
                  response.requestID == requestID else {
                return
            }
            clearPendingRequest()
            handleConnectResponse(response.value, flowID: flowID, requestID: requestID)
        } catch let error as CheckedFFIClientError {
            let failure: HostKeyTrustFailure = error == .timeout
                ? .timeout(nil)
                : .client(error)
            failIfCurrent(failure, flowID: flowID, requestID: requestID)
        } catch {
            failIfCurrent(.client(.protocolViolation), flowID: flowID, requestID: requestID)
        }
    }

    private func persist(
        challenge: HostKeyChallengePayload,
        context active: FlowContext,
        comment: String?
    ) async {
        guard context?.flowID == active.flowID else { return }
        let requestID = HostKeyRequestID()
        var updated = active
        updated.pendingRequestID = requestID
        context = updated
        state = .persisting(active.flowID, challenge, requestID)

        do {
            let client = self.client
            let challengeID = challenge.challengeID
            guard let challengeRequestID = challenge.requestID else {
                state = .failed(active.flowID, .protocolViolation)
                return
            }
            let response = try await withTimeout {
                try await client.acceptAndPersistHostKey(
                    requestID: requestID,
                    challengeRequestID: challengeRequestID,
                    challengeID: challengeID,
                    comment: comment
                )
            }
            guard isCurrent(flowID: active.flowID, requestID: requestID),
                  response.requestID == requestID else {
                return
            }
            clearPendingRequest()
            switch response.value {
            case let .persisted(payload):
                guard payload.challengeID == challenge.challengeID else {
                    state = .failed(active.flowID, .protocolViolation)
                    return
                }
                await connect(flowID: active.flowID, phase: .reconnect)
            case let .failure(error):
                state = .failed(active.flowID, .storeSave(challenge, error))
            }
        } catch let error as CheckedFFIClientError {
            let failure: HostKeyTrustFailure = error == .timeout
                ? .timeout(nil)
                : .client(error)
            failIfCurrent(failure, flowID: active.flowID, requestID: requestID)
        } catch {
            failIfCurrent(.client(.protocolViolation), flowID: active.flowID, requestID: requestID)
        }
    }

    private func handleConnectResponse(
        _ response: CheckedConnectResponse,
        flowID: HostKeyFlowID,
        requestID: HostKeyRequestID
    ) {
        switch response {
        case let .connected(payload):
            state = .connected(flowID, payload.sessionID)
            context = nil
        case let .challenge(payload):
            guard payload.requestID == requestID else { return }
            state = .awaitingUserDecision(flowID, payload)
        case let .blocked(payload):
            state = .blocked(flowID, payload)
        case let .failure(error):
            state = .failed(flowID, classify(error))
        }
    }

    private func classify(_ error: CheckedFFIErrorPayload) -> HostKeyTrustFailure {
        switch error.code.rawValue {
        case "ssh_auth_failed": .authentication(error)
        case "ssh_connect_failed": .network(error)
        case "ssh_timeout": .timeout(error)
        case "known_hosts_read_failed", "known_hosts_permission_denied",
             "known_hosts_file_too_large": .store(error)
        default: .operation(error)
        }
    }

    private func isCurrent(flowID: HostKeyFlowID, requestID: HostKeyRequestID) -> Bool {
        context?.flowID == flowID && context?.pendingRequestID == requestID
    }

    private func clearPendingRequest() {
        context?.pendingRequestID = nil
    }

    private func failIfCurrent(
        _ failure: HostKeyTrustFailure,
        flowID: HostKeyFlowID,
        requestID: HostKeyRequestID
    ) {
        guard isCurrent(flowID: flowID, requestID: requestID) else { return }
        clearPendingRequest()
        state = .failed(flowID, failure)
    }

    private func withTimeout<Value: Sendable>(
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let timeout = operationTimeoutNanoseconds
        return try await withCheckedThrowingContinuation { continuation in
            let race = CheckedOperationRace(continuation: continuation)
            let operationTask = Task.detached {
                do {
                    race.succeed(try await operation())
                } catch let error as CheckedFFIClientError {
                    race.fail(error)
                } catch {
                    race.fail(.protocolViolation)
                }
            }
            let timeoutTask = Task.detached {
                do {
                    try await Task.sleep(nanoseconds: timeout)
                    race.fail(.timeout)
                } catch {
                    // The operation won the race and cancelled this timer.
                }
            }
            race.install(operationTask: operationTask, timeoutTask: timeoutTask)
        }
    }

    private struct FlowContext {
        let flowID: HostKeyFlowID
        let input: CheckedConnectInput
        var pendingRequestID: HostKeyRequestID?
    }
}

private final class CheckedOperationRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    init(continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func install(
        operationTask: Task<Void, Never>,
        timeoutTask: Task<Void, Never>
    ) {
        lock.lock()
        if finished {
            lock.unlock()
            operationTask.cancel()
            timeoutTask.cancel()
            return
        }
        self.operationTask = operationTask
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    func succeed(_ value: Value) {
        finish(.success(value))
    }

    func fail(_ error: CheckedFFIClientError) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Value, CheckedFFIClientError>) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        let operationTask = self.operationTask
        let timeoutTask = self.timeoutTask
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation.resume(with: result.mapError { $0 as Error })
    }
}
