import Foundation

struct CheckedMonitorBinding: Hashable, Sendable {
    let workspaceID: UUID
    let baseSessionID: BaseSessionID
}

enum CheckedMonitorServiceError: Error, Hashable, Sendable {
    case requiresVerifiedSession
    case checkedMonitorSnapshotFailed(CheckedFFIErrorCode?)
    case requestIDMismatch
    case unexpectedKind
    case legacyMonitorDisabledInCheckedMode
    case sessionClosed
    case pollingCancelled
    case unknownCheckedFFIError
    case invalidBaseSessionID
    case internalInvariant
}

extension CheckedMonitorServiceError {
    /// A transport or snapshot failure can be transient while the checked SSH
    /// lease remains valid.  Only faults that prove the lease or protocol is
    /// no longer usable stop the polling loop permanently.
    var shouldContinuePolling: Bool {
        switch self {
        case .checkedMonitorSnapshotFailed, .unknownCheckedFFIError:
            true
        case .requiresVerifiedSession, .requestIDMismatch, .unexpectedKind,
             .legacyMonitorDisabledInCheckedMode, .sessionClosed,
             .pollingCancelled, .invalidBaseSessionID, .internalInvariant:
            false
        }
    }

    var retryMessage: String {
        "监控采样暂时失败，正在重试"
    }
}

extension CheckedMonitorServiceError: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        switch self {
        case .requiresVerifiedSession: "monitor_requires_verified_session"
        case let .checkedMonitorSnapshotFailed(code):
            "monitor_checked_snapshot_failed:\(code?.rawValue ?? "unknown")"
        case .requestIDMismatch: "monitor_request_id_mismatch"
        case .unexpectedKind: "monitor_unexpected_result_kind"
        case .legacyMonitorDisabledInCheckedMode: "monitor_legacy_disabled_in_checked_mode"
        case .sessionClosed: "monitor_base_session_closed"
        case .pollingCancelled: "monitor_polling_cancelled"
        case .unknownCheckedFFIError: "monitor_unknown_checked_ffi_error"
        case .invalidBaseSessionID: "monitor_invalid_base_session_id"
        case .internalInvariant: "monitor_internal_invariant"
        }
    }

    var debugDescription: String { description }

    var userMessage: String {
        switch self {
        case .requiresVerifiedSession, .legacyMonitorDisabledInCheckedMode:
            "需要先建立已验证的 SSH 会话"
        case .sessionClosed:
            "已验证会话已关闭，监控已停止"
        case .pollingCancelled:
            "监控已停止"
        case .requestIDMismatch, .unexpectedKind, .unknownCheckedFFIError,
             .invalidBaseSessionID, .internalInvariant:
            "监控安全响应无效，采样已停止"
        case .checkedMonitorSnapshotFailed:
            "监控采样失败，采样已停止"
        }
    }
}

protocol CheckedMonitorSnapshotFetching: Sendable {
    func snapshot(binding: CheckedMonitorBinding) async throws -> MonitorSnapshotPayload
}

actor CheckedMonitorSnapshotService: CheckedMonitorSnapshotFetching {
    private let client: any CheckedFFIClient

    init(client: any CheckedFFIClient) {
        self.client = client
    }

    func snapshot(binding: CheckedMonitorBinding) async throws -> MonitorSnapshotPayload {
        let requestID = HostKeyRequestID()
        do {
            let response = try await client.monitorSnapshotChecked(
                requestID: requestID,
                baseSessionID: binding.baseSessionID
            )
            guard response.requestID == requestID else {
                throw CheckedMonitorServiceError.requestIDMismatch
            }
            guard response.value.baseSessionID == binding.baseSessionID else {
                throw CheckedMonitorServiceError.internalInvariant
            }
            return response.value
        } catch is CancellationError {
            throw CheckedMonitorServiceError.pollingCancelled
        } catch let error as CheckedMonitorServiceError {
            throw error
        } catch let error as CheckedFFIClientError {
            throw Self.map(error)
        } catch {
            throw CheckedMonitorServiceError.unknownCheckedFFIError
        }
    }

    private static func map(_ error: CheckedFFIClientError) -> CheckedMonitorServiceError {
        switch error {
        case .requestIDMismatch:
            .requestIDMismatch
        case .unexpectedKind, .unknownKind:
            .unexpectedKind
        case let .ffiErrorPayload(payload):
            switch payload.code.rawValue {
            case "session_not_found", "session_closed", "session_draining",
                 "session_terminating", "legacy_session_not_allowed",
                 "verified_session_required", "security_generation_mismatch":
                .sessionClosed
            default:
                .checkedMonitorSnapshotFailed(payload.code)
            }
        case .cancelled:
            .pollingCancelled
        case .invalidInput:
            .invalidBaseSessionID
        case .unavailable, .timeout, .protocolViolation, .nullCStringResult,
             .invalidUTF8Result, .jsonDecodeFailed, .unsupportedSchema,
             .internalInvariant:
            .unknownCheckedFFIError
        }
    }
}

enum MonitorConnectionPlan: Hashable, Sendable {
    case legacy
    case checked(VerifiedWorkspaceSession)
    case rejected(CheckedMonitorServiceError)
}

struct MonitorConnectionPolicy: Sendable {
    let mode: ConnectionSecurityPolicy

    func plan(verifiedSession: VerifiedWorkspaceSession?) -> MonitorConnectionPlan {
        if mode.allowsLegacyNetwork {
            return .legacy
        }
        if let verifiedSession {
            return .checked(verifiedSession)
        }
        return .rejected(.requiresVerifiedSession)
    }
}

actor CheckedMonitorPollingLoop {
    typealias EventHandler = @Sendable (
        Result<MonitorSnapshotPayload, CheckedMonitorServiceError>
    ) async -> Void

    private let binding: CheckedMonitorBinding
    private let fetcher: any CheckedMonitorSnapshotFetching
    private let intervalNanoseconds: UInt64
    private let isEnabled: @Sendable () -> Bool
    private let retryDelayNanoseconds: UInt64
    private var task: Task<Void, Never>?
    private var activeRunID: UUID?

    init(
        binding: CheckedMonitorBinding,
        fetcher: any CheckedMonitorSnapshotFetching,
        intervalNanoseconds: UInt64,
        retryDelayNanoseconds: UInt64 = 1_000_000_000,
        isEnabled: @escaping @Sendable () -> Bool = { true }
    ) {
        self.binding = binding
        self.fetcher = fetcher
        self.intervalNanoseconds = intervalNanoseconds
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.isEnabled = isEnabled
    }

    deinit {
        task?.cancel()
    }

    func start(handler: @escaping EventHandler) {
        guard task == nil else { return }
        let runID = UUID()
        activeRunID = runID
        task = Task { [weak self] in
            await self?.run(runID: runID, handler: handler)
        }
    }

    func stop() {
        activeRunID = nil
        task?.cancel()
        task = nil
    }

    func isRunning() -> Bool {
        task != nil && activeRunID != nil
    }

    private func run(runID: UUID, handler: @escaping EventHandler) async {
        while !Task.isCancelled, activeRunID == runID {
            if !isEnabled() {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
                continue
            }
            let span = PerformanceSignpost.begin(.monitorRefresh)
            do {
                let payload = try await fetcher.snapshot(binding: binding)
                guard !Task.isCancelled, activeRunID == runID else {
                    span.cancel()
                    return
                }
                await handler(.success(payload))
                span.finish()
            } catch {
                span.cancel()
                guard !Task.isCancelled, activeRunID == runID else { return }
                let mapped = error as? CheckedMonitorServiceError ?? .unknownCheckedFFIError
                await handler(.failure(mapped))
                guard mapped.shouldContinuePolling else {
                    finish(runID: runID)
                    return
                }
                do {
                    try await Task.sleep(nanoseconds: retryDelayNanoseconds)
                } catch {
                    return
                }
                continue
            }

            if intervalNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    return
                }
            } else {
                await Task.yield()
            }
        }
        finish(runID: runID)
    }

    private func finish(runID: UUID) {
        guard activeRunID == runID else { return }
        activeRunID = nil
        task = nil
    }
}
