import Foundation

enum CheckedFFIErrorCode: Hashable, Sendable, Codable {
    case known(String)
    case unknown(String)

    private static let supported: Set<String> = [
        "host_key_unknown", "host_key_changed", "host_key_revoked", "host_key_unsupported",
        "host_key_invalid", "known_hosts_read_failed", "known_hosts_save_failed",
        "known_hosts_permission_denied", "known_hosts_file_too_large", "challenge_not_found",
        "challenge_expired", "challenge_already_resolved", "challenge_mismatch",
        "pending_limit_reached", "per_host_pending_limit_reached",
        "related_request_limit_reached", "invalid_request", "invalid_json", "invalid_utf8",
        "ffi_internal_error", "ssh_connect_failed", "ssh_auth_failed", "ssh_timeout",
        "session_pool_failed", "session_not_found", "legacy_session_not_allowed",
        "verified_session_required", "security_generation_mismatch", "session_draining",
        "session_terminating", "session_closed", "channel_open_failed",
        "invalid_pty_size", "pty_request_failed", "shell_start_failed",
        "subsystem_request_failed", "sftp_registration_failed", "exec_request_failed",
        "exec_output_failed", "exec_timeout", "exec_command_failed", "monitor_snapshot_failed",
        "invalid_command", "command_too_large", "invalid_exec_options",
        "exec_output_limit_exceeded",
        "docker_invalid_container_id", "docker_invalid_container_name", "docker_invalid_action",
        "docker_invalid_logs_tail", "docker_invalid_update_option", "docker_command_failed",
        "docker_parse_failed"
    ]

    init(rawValue: String) {
        self = Self.supported.contains(rawValue) ? .known(rawValue) : .unknown(rawValue)
    }

    var rawValue: String {
        switch self {
        case let .known(value), let .unknown(value): value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct CheckedFFIErrorPayload: Error, Hashable, Sendable, Codable,
    CustomStringConvertible, CustomDebugStringConvertible {
    let code: CheckedFFIErrorCode
    let messageKey: String
    let detailCode: String?
    let retryable: Bool
    let requestID: HostKeyRequestID?
    let challengeID: String?

    private enum CodingKeys: String, CodingKey {
        case code
        case messageKey = "message_key"
        case detailCode = "detail_code"
        case retryable
        case requestID = "request_id"
        case challengeID = "challenge_id"
    }

    var description: String {
        "CheckedFFIError(code: \(code.rawValue), retryable: \(retryable))"
    }

    var debugDescription: String { description }
}
