import Foundation

enum CheckedFFIResultKind: Hashable, Sendable, Codable {
    case connected
    case connectionTestSucceeded
    case sftpChannelOpened
    case terminalChannelOpened
    case monitorSnapshot
    case dockerContainers
    case dockerStats
    case dockerLogs
    case dockerActionResult
    case execResult
    case localTunnelStarted
    case localTunnelStopped
    case hostKeyChallenge
    case hostKeyChallengeAccepted
    case hostKeyChallengeStatus
    case hostKeyCleanupCompleted
    case hostKeyBlocked
    case hostKeyTrustPersisted
    case hostKeyRejected
    case protocolVersion
    case error
    case unknown(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    init(rawValue: String) {
        switch rawValue {
        case "connected": self = .connected
        case "connection_test_succeeded": self = .connectionTestSucceeded
        case "sftp_channel_opened": self = .sftpChannelOpened
        case "terminal_channel_opened": self = .terminalChannelOpened
        case "monitor_snapshot": self = .monitorSnapshot
        case "docker_containers": self = .dockerContainers
        case "docker_stats": self = .dockerStats
        case "docker_logs": self = .dockerLogs
        case "docker_action_result": self = .dockerActionResult
        case "exec_result": self = .execResult
        case "local_tunnel_started": self = .localTunnelStarted
        case "local_tunnel_stopped": self = .localTunnelStopped
        case "host_key_challenge": self = .hostKeyChallenge
        case "host_key_challenge_accepted": self = .hostKeyChallengeAccepted
        case "host_key_challenge_status": self = .hostKeyChallengeStatus
        case "host_key_cleanup_completed": self = .hostKeyCleanupCompleted
        case "host_key_blocked": self = .hostKeyBlocked
        case "host_key_trust_persisted": self = .hostKeyTrustPersisted
        case "host_key_rejected": self = .hostKeyRejected
        case "protocol_version": self = .protocolVersion
        case "error": self = .error
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .connected: "connected"
        case .connectionTestSucceeded: "connection_test_succeeded"
        case .sftpChannelOpened: "sftp_channel_opened"
        case .terminalChannelOpened: "terminal_channel_opened"
        case .monitorSnapshot: "monitor_snapshot"
        case .dockerContainers: "docker_containers"
        case .dockerStats: "docker_stats"
        case .dockerLogs: "docker_logs"
        case .dockerActionResult: "docker_action_result"
        case .execResult: "exec_result"
        case .localTunnelStarted: "local_tunnel_started"
        case .localTunnelStopped: "local_tunnel_stopped"
        case .hostKeyChallenge: "host_key_challenge"
        case .hostKeyChallengeAccepted: "host_key_challenge_accepted"
        case .hostKeyChallengeStatus: "host_key_challenge_status"
        case .hostKeyCleanupCompleted: "host_key_cleanup_completed"
        case .hostKeyBlocked: "host_key_blocked"
        case .hostKeyTrustPersisted: "host_key_trust_persisted"
        case .hostKeyRejected: "host_key_rejected"
        case .protocolVersion: "protocol_version"
        case .error: "error"
        case let .unknown(rawValue): rawValue
        }
    }
}

enum CheckedFFISecurityGeneration: Hashable, Sendable, Codable {
    case hostKeyVerified
    case unknown(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = rawValue == "host_key_verified" ? .hostKeyVerified : .unknown(rawValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .hostKeyVerified:
            try container.encode("host_key_verified")
        case let .unknown(rawValue):
            try container.encode(rawValue)
        }
    }
}
