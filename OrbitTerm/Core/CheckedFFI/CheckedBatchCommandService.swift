import Foundation

struct CheckedBatchTarget: Hashable, Sendable {
    let workspaceID: UUID
    let displayName: String
    let endpoint: String
    let baseSessionID: BaseSessionID?

    init(
        workspaceID: UUID,
        displayName: String,
        endpoint: String,
        baseSessionID: BaseSessionID?
    ) {
        self.workspaceID = workspaceID
        self.displayName = displayName
        self.endpoint = endpoint
        self.baseSessionID = baseSessionID
    }
}

enum CheckedBatchTargetStatus: Hashable, Sendable {
    case pending
    case requiresVerifiedSession
    case awaitingHostKeyDecision
    case blocked
    case running
    case succeeded
    case failed
    case cancelled
}

struct CheckedBatchTargetResult: Hashable, Sendable, CustomDebugStringConvertible {
    let workspaceID: UUID
    let displayName: String
    let endpoint: String
    let status: CheckedBatchTargetStatus
    let exitStatus: Int?
    let stdout: String
    let stderr: String
    let error: CheckedBatchCommandError?
    let durationMS: Int

    var succeeded: Bool { status == .succeeded }

    var displayOutput: String {
        if let error {
            return error.userMessage
        }
        let joined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        return joined.isEmpty ? "(无输出)" : joined
    }

    var debugDescription: String {
        "CheckedBatchTargetResult(target: \(displayName), status: \(status), stdout: [REDACTED], stderr: [REDACTED])"
    }
}

enum CheckedBatchCommandError: Error, Hashable, Sendable {
    case invalidCommand
    case commandTooLarge
    case multilineUnsupported
    case requiresVerifiedSession
    case hostKeyBlocked
    case authFailed
    case networkFailed
    case requestIDMismatch
    case unexpectedKind
    case execCommandFailed(Int)
    case execTimeout
    case execOutputLimitExceeded
    case checkedExecFailed(CheckedFFIErrorCode?)
    case batchCancelled
    case legacyBatchDisabledInCheckedMode
    case unknownCheckedFFIError
    case internalInvariant
}

extension CheckedBatchCommandError: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        switch self {
        case .invalidCommand: "batch_invalid_command"
        case .commandTooLarge: "batch_command_too_large"
        case .multilineUnsupported: "batch_multiline_unsupported"
        case .requiresVerifiedSession: "batch_requires_verified_session"
        case .hostKeyBlocked: "batch_host_key_blocked"
        case .authFailed: "batch_auth_failed"
        case .networkFailed: "batch_network_failed"
        case .requestIDMismatch: "batch_request_id_mismatch"
        case .unexpectedKind: "batch_unexpected_result_kind"
        case let .execCommandFailed(status): "batch_exec_command_failed:\(status)"
        case .execTimeout: "batch_exec_timeout"
        case .execOutputLimitExceeded: "batch_exec_output_limit_exceeded"
        case let .checkedExecFailed(code): "batch_checked_exec_failed:\(code?.rawValue ?? "unknown")"
        case .batchCancelled: "batch_cancelled"
        case .legacyBatchDisabledInCheckedMode: "batch_legacy_disabled_in_checked_mode"
        case .unknownCheckedFFIError: "batch_unknown_checked_ffi_error"
        case .internalInvariant: "batch_internal_invariant"
        }
    }

    var debugDescription: String { description }

    var userMessage: String {
        switch self {
        case .invalidCommand:
            "命令不能为空，且不能包含控制字符"
        case .commandTooLarge:
            "命令过长，checked mode 当前限制为 16 KiB"
        case .multilineUnsupported:
            "checked mode 当前只支持单行命令"
        case .requiresVerifiedSession, .legacyBatchDisabledInCheckedMode:
            "需要先建立已验证的 SSH 会话"
        case .hostKeyBlocked:
            "服务器身份校验被阻断，命令未执行"
        case .authFailed:
            "认证失败，命令未执行"
        case .networkFailed:
            "网络连接失败，命令未执行"
        case .requestIDMismatch, .unexpectedKind, .unknownCheckedFFIError, .internalInvariant:
            "Batch 安全响应无效，命令未执行"
        case let .execCommandFailed(status):
            "命令退出状态：\(status)"
        case .execTimeout:
            "命令执行超时"
        case .execOutputLimitExceeded:
            "命令输出超过安全上限"
        case .checkedExecFailed:
            "checked exec 执行失败"
        case .batchCancelled:
            "Batch 已取消"
        }
    }
}

struct CheckedBatchCommandValidator: Sendable {
    static let maximumCommandBytes = 16_384

    func validate(_ command: String) throws -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CheckedBatchCommandError.invalidCommand
        }
        guard trimmed.utf8.count <= Self.maximumCommandBytes else {
            throw CheckedBatchCommandError.commandTooLarge
        }
        for scalar in trimmed.unicodeScalars {
            if scalar.value == 10 || scalar.value == 13 {
                throw CheckedBatchCommandError.multilineUnsupported
            }
            if scalar.value == 9 || CharacterSet.controlCharacters.contains(scalar) {
                throw CheckedBatchCommandError.invalidCommand
            }
        }
        return trimmed
    }
}

actor CheckedBatchCommandService {
    private let client: any CheckedFFIClient
    private let validator: CheckedBatchCommandValidator
    private var activeRunID: UUID?

    init(
        client: any CheckedFFIClient,
        validator: CheckedBatchCommandValidator = CheckedBatchCommandValidator()
    ) {
        self.client = client
        self.validator = validator
    }

    func execute(
        command: String,
        targets: [CheckedBatchTarget],
        options: CheckedExecOptions = .defaults
    ) async -> [CheckedBatchTargetResult] {
        let runID = UUID()
        activeRunID = runID

        let validatedCommand: String
        do {
            validatedCommand = try validator.validate(command)
            guard options.isValid else {
                throw CheckedBatchCommandError.checkedExecFailed(.known("invalid_exec_options"))
            }
        } catch let error as CheckedBatchCommandError {
            finish(runID: runID)
            return targets.map { result(for: $0, status: .failed, error: error) }
        } catch {
            finish(runID: runID)
            return targets.map { result(for: $0, status: .failed, error: .unknownCheckedFFIError) }
        }

        var results: [CheckedBatchTargetResult] = []
        for target in targets {
            guard activeRunID == runID, !Task.isCancelled else {
                results.append(result(for: target, status: .cancelled, error: .batchCancelled))
                continue
            }
            guard let baseSessionID = target.baseSessionID else {
                results.append(
                    result(
                        for: target,
                        status: .requiresVerifiedSession,
                        error: .requiresVerifiedSession
                    )
                )
                continue
            }
            results.append(
                await executeTarget(
                    target,
                    baseSessionID: baseSessionID,
                    command: validatedCommand,
                    options: options,
                    runID: runID
                )
            )
        }
        finish(runID: runID)
        return results
    }

    func cancel() {
        activeRunID = nil
    }

    private func executeTarget(
        _ target: CheckedBatchTarget,
        baseSessionID: BaseSessionID,
        command: String,
        options: CheckedExecOptions,
        runID: UUID
    ) async -> CheckedBatchTargetResult {
        let start = Date()
        let requestID = HostKeyRequestID()
        do {
            let response = try await client.execChecked(
                requestID: requestID,
                baseSessionID: baseSessionID,
                command: command,
                options: options
            )
            guard activeRunID == runID, !Task.isCancelled else {
                return result(for: target, status: .cancelled, error: .batchCancelled, start: start)
            }
            guard response.requestID == requestID,
                  response.value.baseSessionID == baseSessionID else {
                return result(for: target, status: .failed, error: .requestIDMismatch, start: start)
            }
            let payload = response.value
            if payload.timedOut {
                return result(for: target, status: .failed, error: .execTimeout, start: start)
            }
            if payload.stdoutTruncated || payload.stderrTruncated {
                return result(
                    for: target,
                    status: .failed,
                    error: .execOutputLimitExceeded,
                    start: start
                )
            }
            if payload.exitStatus != 0 {
                return CheckedBatchTargetResult(
                    workspaceID: target.workspaceID,
                    displayName: target.displayName,
                    endpoint: target.endpoint,
                    status: .failed,
                    exitStatus: payload.exitStatus,
                    stdout: payload.stdout,
                    stderr: payload.stderr,
                    error: .execCommandFailed(payload.exitStatus),
                    durationMS: durationMS(since: start)
                )
            }
            return CheckedBatchTargetResult(
                workspaceID: target.workspaceID,
                displayName: target.displayName,
                endpoint: target.endpoint,
                status: .succeeded,
                exitStatus: payload.exitStatus,
                stdout: payload.stdout,
                stderr: payload.stderr,
                error: nil,
                durationMS: durationMS(since: start)
            )
        } catch is CancellationError {
            return result(for: target, status: .cancelled, error: .batchCancelled, start: start)
        } catch let error as CheckedFFIClientError {
            return result(for: target, status: .failed, error: Self.map(error), start: start)
        } catch let error as CheckedBatchCommandError {
            return result(for: target, status: .failed, error: error, start: start)
        } catch {
            return result(for: target, status: .failed, error: .unknownCheckedFFIError, start: start)
        }
    }

    private static func map(_ error: CheckedFFIClientError) -> CheckedBatchCommandError {
        switch error {
        case .requestIDMismatch:
            .requestIDMismatch
        case .unexpectedKind, .unknownKind:
            .unexpectedKind
        case let .ffiErrorPayload(payload):
            switch payload.code.rawValue {
            case "exec_timeout": .execTimeout
            case "exec_output_limit_exceeded": .execOutputLimitExceeded
            case "exec_command_failed": .execCommandFailed(-1)
            case "ssh_auth_failed": .authFailed
            case "ssh_connect_failed", "ssh_timeout": .networkFailed
            case "host_key_changed", "host_key_revoked": .hostKeyBlocked
            case "session_not_found", "session_closed", "session_draining",
                 "session_terminating", "legacy_session_not_allowed",
                 "verified_session_required", "security_generation_mismatch":
                .requiresVerifiedSession
            default:
                .checkedExecFailed(payload.code)
            }
        case .cancelled:
            .batchCancelled
        case .timeout:
            .execTimeout
        case .invalidInput:
            .invalidCommand
        case .unavailable, .protocolViolation, .nullCStringResult, .invalidUTF8Result,
             .jsonDecodeFailed, .unsupportedSchema, .internalInvariant:
            .unknownCheckedFFIError
        }
    }

    private func result(
        for target: CheckedBatchTarget,
        status: CheckedBatchTargetStatus,
        error: CheckedBatchCommandError?,
        start: Date = Date()
    ) -> CheckedBatchTargetResult {
        CheckedBatchTargetResult(
            workspaceID: target.workspaceID,
            displayName: target.displayName,
            endpoint: target.endpoint,
            status: status,
            exitStatus: nil,
            stdout: "",
            stderr: "",
            error: error,
            durationMS: durationMS(since: start)
        )
    }

    private func finish(runID: UUID) {
        guard activeRunID == runID else { return }
        activeRunID = nil
    }

    private func durationMS(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1_000)
    }
}

enum BatchCommandConnectionPlan: Hashable, Sendable {
    case legacy
    case checked([CheckedBatchTarget])
    case rejected(CheckedBatchCommandError)
}

struct BatchCommandConnectionPolicy: Sendable {
    let mode: ConnectionSecurityPolicy

    func plan(targets: [CheckedBatchTarget]) -> BatchCommandConnectionPlan {
        if mode.allowsLegacyNetwork {
            return .legacy
        }
        return targets.isEmpty ? .rejected(.requiresVerifiedSession) : .checked(targets)
    }
}
