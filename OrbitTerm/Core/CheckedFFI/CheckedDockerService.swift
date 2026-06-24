import Foundation

struct CheckedDockerBinding: Hashable, Sendable {
    let workspaceID: UUID
    let baseSessionID: BaseSessionID
}

enum CheckedDockerAction: String, CaseIterable, Hashable, Sendable {
    case start
    case stop
    case restart
    case kill
    case pause
    case unpause
    case remove
}

struct CheckedDockerRefresh: Hashable, Sendable {
    let containers: DockerContainersPayload
    let stats: DockerStatsPayload
}

enum CheckedDockerServiceError: Error, Hashable, Sendable {
    case requiresVerifiedSession
    case checkedDockerOperationFailed(CheckedFFIErrorCode?)
    case requestIDMismatch
    case unexpectedKind
    case legacyDockerDisabledInCheckedMode
    case sessionClosed
    case refreshCancelled
    case renameUpdateDisabledInCheckedMode
    case unknownCheckedFFIError
    case invalidBaseSessionID
    case invalidContainerID
    case invalidDockerAction
    case internalInvariant
}

extension CheckedDockerServiceError: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        switch self {
        case .requiresVerifiedSession: "docker_requires_verified_session"
        case let .checkedDockerOperationFailed(code):
            "docker_checked_operation_failed:\(code?.rawValue ?? "unknown")"
        case .requestIDMismatch: "docker_request_id_mismatch"
        case .unexpectedKind: "docker_unexpected_result_kind"
        case .legacyDockerDisabledInCheckedMode: "docker_legacy_disabled_in_checked_mode"
        case .sessionClosed: "docker_base_session_closed"
        case .refreshCancelled: "docker_refresh_cancelled"
        case .renameUpdateDisabledInCheckedMode: "docker_rename_update_disabled_in_checked_mode"
        case .unknownCheckedFFIError: "docker_unknown_checked_ffi_error"
        case .invalidBaseSessionID: "docker_invalid_base_session_id"
        case .invalidContainerID: "docker_invalid_container_id"
        case .invalidDockerAction: "docker_invalid_action"
        case .internalInvariant: "docker_internal_invariant"
        }
    }

    var debugDescription: String { description }

    var userMessage: String {
        switch self {
        case .requiresVerifiedSession, .legacyDockerDisabledInCheckedMode:
            "需要先建立已验证的 SSH 会话"
        case .sessionClosed:
            "已验证会话已关闭，Docker 已停止"
        case .refreshCancelled:
            "Docker 刷新已停止"
        case .renameUpdateDisabledInCheckedMode:
            "此操作将在安全接口完成后启用"
        case .invalidContainerID, .invalidDockerAction:
            "Docker 操作参数无效"
        case .requestIDMismatch, .unexpectedKind, .unknownCheckedFFIError,
             .invalidBaseSessionID, .internalInvariant:
            "Docker 安全响应无效，操作已停止"
        case .checkedDockerOperationFailed:
            "Docker 安全操作失败"
        }
    }
}

protocol CheckedDockerOperating: Sendable {
    func refresh(binding: CheckedDockerBinding) async throws -> CheckedDockerRefresh
    func logs(
        binding: CheckedDockerBinding,
        containerID: String,
        tail: UInt32
    ) async throws -> DockerLogsPayload
    func perform(
        binding: CheckedDockerBinding,
        containerID: String,
        action: CheckedDockerAction
    ) async throws -> DockerActionResultPayload
}

actor CheckedDockerOperationService: CheckedDockerOperating {
    private let client: any CheckedFFIClient

    init(client: any CheckedFFIClient) {
        self.client = client
    }

    func refresh(binding: CheckedDockerBinding) async throws -> CheckedDockerRefresh {
        let containers: DockerContainersPayload = try await call(
            baseSessionID: binding.baseSessionID
        ) { requestID in
            try await client.dockerListChecked(
                requestID: requestID,
                baseSessionID: binding.baseSessionID
            )
        }
        let stats: DockerStatsPayload = try await call(
            baseSessionID: binding.baseSessionID
        ) { requestID in
            try await client.dockerStatsChecked(
                requestID: requestID,
                baseSessionID: binding.baseSessionID
            )
        }
        return CheckedDockerRefresh(containers: containers, stats: stats)
    }

    func logs(
        binding: CheckedDockerBinding,
        containerID: String,
        tail: UInt32
    ) async throws -> DockerLogsPayload {
        guard Self.validContainerID(containerID) else {
            throw CheckedDockerServiceError.invalidContainerID
        }
        guard tail <= 10_000 else {
            throw CheckedDockerServiceError.checkedDockerOperationFailed(
                .known("docker_invalid_logs_tail")
            )
        }
        let payload: DockerLogsPayload = try await call(
            baseSessionID: binding.baseSessionID
        ) { requestID in
            try await client.dockerLogsChecked(
                requestID: requestID,
                baseSessionID: binding.baseSessionID,
                containerID: containerID,
                tail: tail
            )
        }
        guard payload.containerID == containerID else {
            throw CheckedDockerServiceError.internalInvariant
        }
        return payload
    }

    func perform(
        binding: CheckedDockerBinding,
        containerID: String,
        action: CheckedDockerAction
    ) async throws -> DockerActionResultPayload {
        guard Self.validContainerID(containerID) else {
            throw CheckedDockerServiceError.invalidContainerID
        }
        let payload: DockerActionResultPayload = try await call(
            baseSessionID: binding.baseSessionID
        ) { requestID in
            try await client.dockerActionChecked(
                requestID: requestID,
                baseSessionID: binding.baseSessionID,
                containerID: containerID,
                action: action.rawValue
            )
        }
        guard payload.containerID == containerID, payload.action == action.rawValue else {
            throw CheckedDockerServiceError.internalInvariant
        }
        return payload
    }

    private func call<Payload: Sendable>(
        baseSessionID: BaseSessionID,
        operation: (HostKeyRequestID) async throws -> CheckedClientResponse<Payload>
    ) async throws -> Payload {
        let requestID = HostKeyRequestID()
        do {
            let response = try await operation(requestID)
            guard response.requestID == requestID else {
                throw CheckedDockerServiceError.requestIDMismatch
            }
            return response.value
        } catch is CancellationError {
            throw CheckedDockerServiceError.refreshCancelled
        } catch let error as CheckedDockerServiceError {
            throw error
        } catch let error as CheckedFFIClientError {
            throw Self.map(error)
        } catch {
            throw CheckedDockerServiceError.unknownCheckedFFIError
        }
    }

    private static func map(_ error: CheckedFFIClientError) -> CheckedDockerServiceError {
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
            case "docker_invalid_container_id":
                .invalidContainerID
            case "docker_invalid_action":
                .invalidDockerAction
            default:
                .checkedDockerOperationFailed(payload.code)
            }
        case .cancelled:
            .refreshCancelled
        case .invalidInput:
            .invalidContainerID
        case .unavailable, .timeout, .protocolViolation, .nullCStringResult,
             .invalidUTF8Result, .jsonDecodeFailed, .unsupportedSchema,
             .internalInvariant:
            .unknownCheckedFFIError
        }
    }

    private static func validContainerID(_ value: String) -> Bool {
        (12 ... 64).contains(value.utf8.count) &&
            value.utf8.allSatisfy { byte in
                (48 ... 57).contains(byte) || (65 ... 70).contains(byte) ||
                    (97 ... 102).contains(byte)
            }
    }
}

enum DockerConnectionPlan: Hashable, Sendable {
    case legacy
    case checked(VerifiedWorkspaceSession)
    case rejected(CheckedDockerServiceError)
}

struct DockerConnectionPolicy: Sendable {
    let mode: ConnectionSecurityPolicy

    func plan(verifiedSession: VerifiedWorkspaceSession?) -> DockerConnectionPlan {
        if mode.allowsLegacyNetwork {
            return .legacy
        }
        if let verifiedSession {
            return .checked(verifiedSession)
        }
        return .rejected(.requiresVerifiedSession)
    }
}

actor CheckedDockerRefreshLoop {
    typealias EventHandler = @Sendable (
        Result<CheckedDockerRefresh, CheckedDockerServiceError>
    ) async -> Void

    private let binding: CheckedDockerBinding
    private let operatorService: any CheckedDockerOperating
    private let intervalNanoseconds: UInt64
    private var task: Task<Void, Never>?
    private var activeRunID: UUID?

    init(
        binding: CheckedDockerBinding,
        operatorService: any CheckedDockerOperating,
        intervalNanoseconds: UInt64
    ) {
        self.binding = binding
        self.operatorService = operatorService
        self.intervalNanoseconds = intervalNanoseconds
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
            do {
                try await Task.sleep(nanoseconds: intervalNanoseconds)
            } catch {
                return
            }
            do {
                let refresh = try await operatorService.refresh(binding: binding)
                guard !Task.isCancelled, activeRunID == runID else { return }
                await handler(.success(refresh))
            } catch {
                guard !Task.isCancelled, activeRunID == runID else { return }
                let mapped = error as? CheckedDockerServiceError ?? .unknownCheckedFFIError
                await handler(.failure(mapped))
                finish(runID: runID)
                return
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
