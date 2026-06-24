import Foundation

struct CredentialAccessReference: Hashable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    let id: UUID
    let allowPasswordFallback: Bool

    init(id: UUID = UUID(), allowPasswordFallback: Bool = true) {
        self.id = id
        self.allowPasswordFallback = allowPasswordFallback
    }

    var description: String { "credential:[REDACTED]" }
    var debugDescription: String { description }
}

struct CheckedConnectInput: Hashable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    let host: String
    let port: UInt16
    let username: String
    let credentialReference: CredentialAccessReference

    var description: String {
        "CheckedConnectInput(host: \(host), port: \(port), credential: [REDACTED])"
    }

    var debugDescription: String { description }
}

struct CheckedClientResponse<Value: Sendable>: Sendable {
    let requestID: HostKeyRequestID
    let value: Value
}

struct CheckedExecOptions: Hashable, Sendable {
    static let defaultTimeoutSeconds: UInt32 = 30
    static let maximumTimeoutSeconds: UInt32 = 300
    static let defaultMaxStdoutBytes: UInt32 = 262_144
    static let maximumStdoutBytes: UInt32 = 1_048_576
    static let defaultMaxStderrBytes: UInt32 = 65_536
    static let maximumStderrBytes: UInt32 = 262_144

    static let defaults = CheckedExecOptions()

    let timeoutSeconds: UInt32
    let maxStdoutBytes: UInt32
    let maxStderrBytes: UInt32

    init(
        timeoutSeconds: UInt32 = Self.defaultTimeoutSeconds,
        maxStdoutBytes: UInt32 = Self.defaultMaxStdoutBytes,
        maxStderrBytes: UInt32 = Self.defaultMaxStderrBytes
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.maxStdoutBytes = maxStdoutBytes
        self.maxStderrBytes = maxStderrBytes
    }

    var isValid: Bool {
        (1 ... Self.maximumTimeoutSeconds).contains(timeoutSeconds) &&
            (1 ... Self.maximumStdoutBytes).contains(maxStdoutBytes) &&
            (1 ... Self.maximumStderrBytes).contains(maxStderrBytes)
    }
}

enum HostKeyTrustPersistResponse: Sendable {
    case persisted(TrustPersistedPayload)
    case failure(CheckedFFIErrorPayload)
}

enum CheckedFFIClientError: Error, Hashable, Sendable {
    case unavailable
    case cancelled
    case timeout
    case protocolViolation
    case nullCStringResult
    case invalidUTF8Result
    case jsonDecodeFailed
    case requestIDMismatch
    case unexpectedKind(CheckedFFIResultKind)
    case ffiErrorPayload(CheckedFFIErrorPayload)
    case invalidInput
    case unsupportedSchema(UInt32)
    case unknownKind(String)
    case internalInvariant
}

extension CheckedFFIClientError: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        switch self {
        case .unavailable: "checked_ffi_unavailable"
        case .cancelled: "checked_ffi_cancelled"
        case .timeout: "checked_ffi_timeout"
        case .protocolViolation: "checked_ffi_protocol_violation"
        case .nullCStringResult: "checked_ffi_null_result"
        case .invalidUTF8Result: "checked_ffi_invalid_utf8"
        case .jsonDecodeFailed: "checked_ffi_json_decode_failed"
        case .requestIDMismatch: "checked_ffi_request_mismatch"
        case let .unexpectedKind(kind): "checked_ffi_unexpected_kind:\(kind.rawValue)"
        case let .ffiErrorPayload(payload): "checked_ffi_error:\(payload.code.rawValue)"
        case .invalidInput: "checked_ffi_invalid_input"
        case let .unsupportedSchema(version): "checked_ffi_unsupported_schema:\(version)"
        case let .unknownKind(kind): "checked_ffi_unknown_kind:\(kind)"
        case .internalInvariant: "checked_ffi_internal_invariant"
        }
    }

    var debugDescription: String { description }
}

protocol CheckedFFIClient: Sendable {
    func connectChecked(
        requestID: HostKeyRequestID,
        input: CheckedConnectInput
    ) async throws -> CheckedClientResponse<CheckedConnectResponse>

    func acceptAndPersistHostKey(
        requestID: HostKeyRequestID,
        challengeRequestID: HostKeyRequestID,
        challengeID: String,
        comment: String?
    ) async throws -> CheckedClientResponse<HostKeyTrustPersistResponse>

    func openTerminalChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID,
        cols: UInt32,
        rows: UInt32
    ) async throws -> CheckedClientResponse<TerminalChannelOpenedPayload>

    func openSFTPChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID
    ) async throws -> CheckedClientResponse<SFTPChannelOpenedPayload>

    func monitorSnapshotChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID
    ) async throws -> CheckedClientResponse<MonitorSnapshotPayload>

    func dockerListChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID
    ) async throws -> CheckedClientResponse<DockerContainersPayload>

    func dockerStatsChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID
    ) async throws -> CheckedClientResponse<DockerStatsPayload>

    func dockerLogsChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID,
        containerID: String,
        tail: UInt32
    ) async throws -> CheckedClientResponse<DockerLogsPayload>

    func dockerActionChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID,
        containerID: String,
        action: String
    ) async throws -> CheckedClientResponse<DockerActionResultPayload>

    func execChecked(
        requestID: HostKeyRequestID,
        baseSessionID: BaseSessionID,
        command: String,
        options: CheckedExecOptions
    ) async throws -> CheckedClientResponse<ExecResultPayload>
}
