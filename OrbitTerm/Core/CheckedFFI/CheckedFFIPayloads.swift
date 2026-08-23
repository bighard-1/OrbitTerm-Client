import Foundation

enum HostKeyChallengeReasonCode: Hashable, Sendable, Codable {
    case unknownHost
    case unknown(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = raw == "unknown_host" ? .unknownHost : .unknown(raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .unknownHost: try container.encode("unknown_host")
        case let .unknown(raw): try container.encode(raw)
        }
    }
}

enum HostKeyBlockReasonCode: Hashable, Sendable, Codable {
    case changed
    case revoked
    case unsupported
    case certAuthorityUnsupported
    case unknown(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "changed": self = .changed
        case "revoked": self = .revoked
        case "unsupported": self = .unsupported
        case "cert_authority_unsupported": self = .certAuthorityUnsupported
        case let raw: self = .unknown(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .changed: try container.encode("changed")
        case .revoked: try container.encode("revoked")
        case .unsupported: try container.encode("unsupported")
        case .certAuthorityUnsupported: try container.encode("cert_authority_unsupported")
        case let .unknown(raw): try container.encode(raw)
        }
    }
}

enum HostKeyKnownState: Hashable, Sendable, Codable {
    case unknownHost
    case trusted
    case changed
    case revoked
    case unsupported
    case invalid
    case error
    case unknownValue(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "unknown": self = .unknownHost
        case "trusted": self = .trusted
        case "changed": self = .changed
        case "revoked": self = .revoked
        case "unsupported": self = .unsupported
        case "invalid": self = .invalid
        case "error": self = .error
        case let raw: self = .unknownValue(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let raw: String
        switch self {
        case .unknownHost: raw = "unknown"
        case .trusted: raw = "trusted"
        case .changed: raw = "changed"
        case .revoked: raw = "revoked"
        case .unsupported: raw = "unsupported"
        case .invalid: raw = "invalid"
        case .error: raw = "error"
        case let .unknownValue(value): raw = value
        }
        try container.encode(raw)
    }
}

enum HostKeyTrustStatus: String, Hashable, Sendable, Codable {
    case trustedAdded = "trusted_added"
    case alreadyTrusted = "already_trusted"
}

struct HostKeyChallengePayload: Hashable, Sendable, Codable, CustomDebugStringConvertible {
    let challengeID: String
    let requestID: HostKeyRequestID?
    let host: String
    let normalizedHost: String
    let port: UInt16
    let lookupToken: String
    let keyAlgorithm: String
    let fingerprintSHA256: String
    let reasonCode: HostKeyChallengeReasonCode
    let knownState: HostKeyKnownState
    let canTrust: Bool
    let canReplace: Bool
    let expiresAtUnix: UInt64
    let reusedExistingChallenge: Bool
    let relatedRequestCount: UInt32

    private enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case requestID = "request_id"
        case host
        case normalizedHost = "normalized_host"
        case port
        case lookupToken = "lookup_token"
        case keyAlgorithm = "key_algorithm"
        case fingerprintSHA256 = "fingerprint_sha256"
        case reasonCode = "reason_code"
        case knownState = "known_state"
        case canTrust = "can_trust"
        case canReplace = "can_replace"
        case expiresAtUnix = "expires_at_unix"
        case reusedExistingChallenge = "reused_existing_challenge"
        case relatedRequestCount = "related_request_count"
    }

    var debugDescription: String {
        "HostKeyChallenge(host: \(normalizedHost), port: \(port), algorithm: \(keyAlgorithm))"
    }
}

struct HostKeyBlockedPayload: Hashable, Sendable, Codable, CustomDebugStringConvertible {
    let host: String
    let normalizedHost: String
    let port: UInt16
    let lookupToken: String
    let keyAlgorithm: String
    let presentedFingerprintSHA256: String
    let previousFingerprintSHA256: String?
    let reasonCode: HostKeyBlockReasonCode
    let knownState: HostKeyKnownState
    let canTrust: Bool
    let canReplace: Bool
    let messageKey: String

    private enum CodingKeys: String, CodingKey {
        case host
        case normalizedHost = "normalized_host"
        case port
        case lookupToken = "lookup_token"
        case keyAlgorithm = "key_algorithm"
        case presentedFingerprintSHA256 = "presented_fingerprint_sha256"
        case previousFingerprintSHA256 = "previous_fingerprint_sha256"
        case reasonCode = "reason_code"
        case knownState = "known_state"
        case canTrust = "can_trust"
        case canReplace = "can_replace"
        case messageKey = "message_key"
    }

    var debugDescription: String {
        "HostKeyBlocked(host: \(normalizedHost), port: \(port), reason: \(reasonCode))"
    }
}

struct TrustPersistedPayload: Hashable, Sendable, Codable, CustomDebugStringConvertible {
    let challengeID: String
    let host: String
    let normalizedHost: String
    let port: UInt16
    let lookupToken: String
    let keyAlgorithm: String
    let fingerprintSHA256: String
    let status: HostKeyTrustStatus

    private enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case host
        case normalizedHost = "normalized_host"
        case port
        case lookupToken = "lookup_token"
        case keyAlgorithm = "key_algorithm"
        case fingerprintSHA256 = "fingerprint_sha256"
        case status
    }

    var debugDescription: String {
        "TrustPersisted(host: \(normalizedHost), status: \(status.rawValue))"
    }
}

struct ConnectedPayload: Hashable, Sendable, Codable, CustomDebugStringConvertible {
    let sessionID: BaseSessionID
    let host: String
    let normalizedHost: String
    let port: UInt16
    let lookupToken: String
    let keyAlgorithm: String
    let fingerprintSHA256: String
    let securityGeneration: CheckedFFISecurityGeneration

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case host
        case normalizedHost = "normalized_host"
        case port
        case lookupToken = "lookup_token"
        case keyAlgorithm = "key_algorithm"
        case fingerprintSHA256 = "fingerprint_sha256"
        case securityGeneration = "security_generation"
    }

    var debugDescription: String {
        "Connected(session: \(sessionID), host: \(normalizedHost), generation: \(securityGeneration))"
    }
}

struct SFTPChannelOpenedPayload: Hashable, Sendable, Codable {
    let baseSessionID: BaseSessionID
    let sftpSessionID: SFTPSessionID
    let homePath: String?
    let securityGeneration: CheckedFFISecurityGeneration

    private enum CodingKeys: String, CodingKey {
        case baseSessionID = "base_session_id"
        case sftpSessionID = "sftp_session_id"
        case homePath = "home_path"
        case securityGeneration = "security_generation"
    }
}

enum CheckedFFIPayloadError: Error, Equatable, Sendable {
    case invalidSecurityGeneration
    case invalidPTYSize
    case invalidExecPayload
}

struct TerminalChannelOpenedPayload: Hashable, Sendable, Codable,
    CustomDebugStringConvertible {
    let baseSessionID: BaseSessionID
    let terminalChannelID: TerminalChannelID
    let securityGeneration: CheckedFFISecurityGeneration
    let cols: UInt32
    let rows: UInt32

    private enum CodingKeys: String, CodingKey {
        case baseSessionID = "base_session_id"
        case terminalChannelID = "terminal_channel_id"
        case securityGeneration = "security_generation"
        case cols, rows
    }

    init(
        baseSessionID: BaseSessionID,
        terminalChannelID: TerminalChannelID,
        securityGeneration: CheckedFFISecurityGeneration,
        cols: UInt32,
        rows: UInt32
    ) throws {
        guard securityGeneration == .hostKeyVerified else {
            throw CheckedFFIPayloadError.invalidSecurityGeneration
        }
        guard (1 ... 1_000).contains(cols), (1 ... 1_000).contains(rows) else {
            throw CheckedFFIPayloadError.invalidPTYSize
        }
        self.baseSessionID = baseSessionID
        self.terminalChannelID = terminalChannelID
        self.securityGeneration = securityGeneration
        self.cols = cols
        self.rows = rows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            baseSessionID: container.decode(BaseSessionID.self, forKey: .baseSessionID),
            terminalChannelID: container.decode(
                TerminalChannelID.self,
                forKey: .terminalChannelID
            ),
            securityGeneration: container.decode(
                CheckedFFISecurityGeneration.self,
                forKey: .securityGeneration
            ),
            cols: container.decode(UInt32.self, forKey: .cols),
            rows: container.decode(UInt32.self, forKey: .rows)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseSessionID, forKey: .baseSessionID)
        try container.encode(terminalChannelID, forKey: .terminalChannelID)
        try container.encode(securityGeneration, forKey: .securityGeneration)
        try container.encode(cols, forKey: .cols)
        try container.encode(rows, forKey: .rows)
    }

    var debugDescription: String {
        "TerminalChannelOpened(base: \(baseSessionID), terminal: \(terminalChannelID), size: \(cols)x\(rows))"
    }
}

struct MonitorSnapshotPayload: Hashable, Sendable, Codable {
    let baseSessionID: BaseSessionID
    let securityGeneration: CheckedFFISecurityGeneration
    let stats: MonitorSnapshotStatsPayload
    let diagnostics: [MonitorSnapshotDiagnostic]

    private enum CodingKeys: String, CodingKey {
        case baseSessionID = "base_session_id"
        case securityGeneration = "security_generation"
        case stats
        case diagnostics
    }
}

struct MonitorSnapshotStatsPayload: Hashable, Sendable, Codable {
    let sampledAtUnix: UInt64
    let cpuUsagePercent: Double
    let memAvailableMB: UInt64
    let memUsedPercent: Double
    let diskUsedPercent: Double
    let pingLatencyMS: Double?
    let rxRateKBPS: Double
    let txRateKBPS: Double
    let systemInfo: MonitorSystemInfo

    private enum CodingKeys: String, CodingKey {
        case sampledAtUnix = "sampled_at_unix"
        case cpuUsagePercent = "cpu_usage_percent"
        case memAvailableMB = "mem_available_mb"
        case memUsedPercent = "mem_used_percent"
        case diskUsedPercent = "disk_used_percent"
        case pingLatencyMS = "ping_latency_ms"
        case rxRateKBPS = "rx_rate_kbps"
        case txRateKBPS = "tx_rate_kbps"
        case systemInfo = "system_info"
    }
}

enum MonitorSnapshotDiagnostic: Hashable, Sendable, Codable {
    case pingUnavailable
    case unknown(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = raw == "ping_unavailable" ? .pingUnavailable : .unknown(raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .pingUnavailable: try container.encode("ping_unavailable")
        case let .unknown(raw): try container.encode(raw)
        }
    }
}

struct DockerContainerPayload: Hashable, Sendable, Codable {
    let id: String
    let name: String
    let image: String
    let state: String
    let status: String
    let runningFor: String

    private enum CodingKeys: String, CodingKey {
        case id, name, image, state, status
        case runningFor = "running_for"
    }
}

struct DockerContainersPayload: Hashable, Sendable, Codable {
    let baseSessionID: BaseSessionID
    let securityGeneration: CheckedFFISecurityGeneration
    let containers: [DockerContainerPayload]

    private enum CodingKeys: String, CodingKey {
        case baseSessionID = "base_session_id"
        case securityGeneration = "security_generation"
        case containers
    }
}

struct DockerStatsItemPayload: Hashable, Sendable, Codable {
    let id: String
    let name: String
    let cpuPercent: Double
    let memPercent: Double
    let memUsage: String
    let netIO: String
    let blockIO: String
    let pids: UInt32

    private enum CodingKeys: String, CodingKey {
        case id, name
        case cpuPercent = "cpu_percent"
        case memPercent = "mem_percent"
        case memUsage = "mem_usage"
        case netIO = "net_io"
        case blockIO = "block_io"
        case pids
    }
}

struct DockerStatsPayload: Hashable, Sendable, Codable {
    let baseSessionID: BaseSessionID
    let securityGeneration: CheckedFFISecurityGeneration
    let stats: [DockerStatsItemPayload]

    private enum CodingKeys: String, CodingKey {
        case baseSessionID = "base_session_id"
        case securityGeneration = "security_generation"
        case stats
    }
}

struct DockerLogsPayload: Hashable, Sendable, Codable, CustomDebugStringConvertible {
    let baseSessionID: BaseSessionID
    let securityGeneration: CheckedFFISecurityGeneration
    let containerID: String
    let logs: String

    private enum CodingKeys: String, CodingKey {
        case baseSessionID = "base_session_id"
        case securityGeneration = "security_generation"
        case containerID = "container_id"
        case logs
    }

    var debugDescription: String {
        "DockerLogs(base: \(baseSessionID), container: [REDACTED], logs: [REDACTED])"
    }
}

enum DockerOperationStatus: String, Hashable, Sendable, Codable {
    case completed
}

struct DockerActionResultPayload: Hashable, Sendable, Codable {
    let baseSessionID: BaseSessionID
    let securityGeneration: CheckedFFISecurityGeneration
    let containerID: String
    let action: String
    let status: DockerOperationStatus

    private enum CodingKeys: String, CodingKey {
        case baseSessionID = "base_session_id"
        case securityGeneration = "security_generation"
        case containerID = "container_id"
        case action
        case status
    }
}

struct ExecResultPayload: Hashable, Sendable, Codable, CustomDebugStringConvertible {
    static let maximumStdoutBytes = 1_048_576
    static let maximumStderrBytes = 262_144

    let baseSessionID: BaseSessionID
    let securityGeneration: CheckedFFISecurityGeneration
    let exitStatus: Int
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let stdoutTruncated: Bool
    let stderrTruncated: Bool

    private enum CodingKeys: String, CodingKey {
        case baseSessionID = "base_session_id"
        case securityGeneration = "security_generation"
        case exitStatus = "exit_status"
        case stdout
        case stderr
        case timedOut = "timed_out"
        case stdoutTruncated = "stdout_truncated"
        case stderrTruncated = "stderr_truncated"
    }

    init(
        baseSessionID: BaseSessionID,
        securityGeneration: CheckedFFISecurityGeneration,
        exitStatus: Int,
        stdout: String,
        stderr: String,
        timedOut: Bool,
        stdoutTruncated: Bool,
        stderrTruncated: Bool
    ) throws {
        guard securityGeneration == .hostKeyVerified,
              exitStatus >= 0,
              stdout.utf8.count <= Self.maximumStdoutBytes,
              stderr.utf8.count <= Self.maximumStderrBytes else {
            throw CheckedFFIPayloadError.invalidExecPayload
        }
        self.baseSessionID = baseSessionID
        self.securityGeneration = securityGeneration
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            baseSessionID: container.decode(BaseSessionID.self, forKey: .baseSessionID),
            securityGeneration: container.decode(
                CheckedFFISecurityGeneration.self,
                forKey: .securityGeneration
            ),
            exitStatus: container.decode(Int.self, forKey: .exitStatus),
            stdout: container.decode(String.self, forKey: .stdout),
            stderr: container.decode(String.self, forKey: .stderr),
            timedOut: container.decode(Bool.self, forKey: .timedOut),
            stdoutTruncated: container.decode(Bool.self, forKey: .stdoutTruncated),
            stderrTruncated: container.decode(Bool.self, forKey: .stderrTruncated)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseSessionID, forKey: .baseSessionID)
        try container.encode(securityGeneration, forKey: .securityGeneration)
        try container.encode(exitStatus, forKey: .exitStatus)
        try container.encode(stdout, forKey: .stdout)
        try container.encode(stderr, forKey: .stderr)
        try container.encode(timedOut, forKey: .timedOut)
        try container.encode(stdoutTruncated, forKey: .stdoutTruncated)
        try container.encode(stderrTruncated, forKey: .stderrTruncated)
    }

    var debugDescription: String {
        "ExecResult(base: \(baseSessionID), exit: \(exitStatus), stdout: [REDACTED], stderr: [REDACTED])"
    }
}
