import Foundation

enum CheckedFFIFixtures {
    static let requestID = "11111111-2222-3333-4444-555555555555"
    static let staleRequestID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    static let largeID = "18446744073709551615"

    static let connected = envelope(
        kind: "connected",
        data: """
        {
          "session_id": 18446744073709551615,
          "host": "fixture.example",
          "normalized_host": "fixture.example",
          "port": 2222,
          "lookup_token": "[fixture.example]:2222",
          "key_algorithm": "ssh-ed25519",
          "fingerprint_sha256": "SHA256:fixtureConnected",
          "security_generation": "host_key_verified"
        }
        """
    )

    static let challenge = envelope(
        kind: "host_key_challenge",
        data: """
        {
          "challenge_id": "challenge-fixture-1",
          "request_id": "\(requestID)",
          "host": "fixture.example",
          "normalized_host": "fixture.example",
          "port": 2222,
          "lookup_token": "[fixture.example]:2222",
          "key_algorithm": "ssh-ed25519",
          "fingerprint_sha256": "SHA256:fixtureChallenge",
          "reason_code": "unknown_host",
          "known_state": "unknown",
          "can_trust": true,
          "can_replace": false,
          "expires_at_unix": 2000000000,
          "reused_existing_challenge": false,
          "related_request_count": 1
        }
        """
    )

    static let blockedChanged = blocked(reason: "changed", knownState: "changed", previous: "\"SHA256:fixturePrevious\"", canReplace: true)
    static let blockedRevoked = blocked(reason: "revoked", knownState: "revoked", previous: "null", canReplace: false)

    static let trustPersisted = envelope(
        kind: "host_key_trust_persisted",
        data: """
        {
          "challenge_id": "challenge-fixture-1",
          "host": "fixture.example",
          "normalized_host": "fixture.example",
          "port": 2222,
          "lookup_token": "[fixture.example]:2222",
          "key_algorithm": "ssh-ed25519",
          "fingerprint_sha256": "SHA256:fixtureChallenge",
          "status": "trusted_added"
        }
        """
    )

    static let sftpOpened = envelope(
        kind: "sftp_channel_opened",
        data: """
        {
          "base_session_id": "\(largeID)",
          "sftp_session_id": "72057594037927937",
          "security_generation": "host_key_verified"
        }
        """
    )

    static let terminalOpened = envelope(
        kind: "terminal_channel_opened",
        data: """
        {
          "base_session_id": "\(largeID)",
          "terminal_channel_id": "18446744073709551614",
          "security_generation": "host_key_verified",
          "cols": 120,
          "rows": 32,
          "future_terminal_field": "ignored"
        }
        """
    )

    static let monitorSnapshot = envelope(
        kind: "monitor_snapshot",
        data: """
        {
          "base_session_id": "72057594037927936",
          "security_generation": "host_key_verified",
          "stats": {
            "sampled_at_unix": 1900000000,
            "cpu_usage_percent": 12.3,
            "mem_available_mb": 4096,
            "mem_used_percent": 45.6,
            "disk_used_percent": 78.9,
            "ping_latency_ms": 4.2,
            "rx_rate_kbps": 10.5,
            "tx_rate_kbps": 3.5,
            "system_info": {
              "os_name": "Linux 6.8.0 x86_64",
              "cpu_core_count": 4,
              "cpu_thread_count": 8,
              "memory_total_mb": 16384,
              "swap_total_mb": 2048,
              "swap_used_mb": 128,
              "disk_total_mb": 512000,
              "disk_used_mb": 192000
            }
          },
          "diagnostics": ["ping_unavailable"]
        }
        """
    )

    static let dockerContainers = envelope(
        kind: "docker_containers",
        data: """
        {
          "base_session_id": "72057594037927936",
          "security_generation": "host_key_verified",
          "containers": [{
            "id": "abcdef123456",
            "name": "fixture-api",
            "image": "fixture/image:1",
            "state": "running",
            "status": "Up 5 minutes",
            "running_for": "5 minutes"
          }]
        }
        """
    )

    static let dockerStats = envelope(
        kind: "docker_stats",
        data: """
        {
          "base_session_id": "72057594037927936",
          "security_generation": "host_key_verified",
          "stats": [{
            "id": "abcdef123456",
            "name": "fixture-api",
            "cpu_percent": 2.5,
            "mem_percent": 10.0,
            "mem_usage": "100MiB / 1GiB",
            "net_io": "1kB / 2kB",
            "block_io": "0B / 0B",
            "pids": 8
          }]
        }
        """
    )

    static let dockerLogs = envelope(
        kind: "docker_logs",
        data: """
        {
          "base_session_id": "72057594037927936",
          "security_generation": "host_key_verified",
          "container_id": "abcdef123456",
          "logs": "fixture log line"
        }
        """
    )

    static let dockerAction = envelope(
        kind: "docker_action_result",
        data: """
        {
          "base_session_id": "72057594037927936",
          "security_generation": "host_key_verified",
          "container_id": "abcdef123456",
          "action": "restart",
          "status": "completed"
        }
        """
    )

    static let execResult = envelope(
        kind: "exec_result",
        data: """
        {
          "base_session_id": "72057594037927936",
          "security_generation": "host_key_verified",
          "exit_status": 0,
          "stdout": "fixture stdout",
          "stderr": "",
          "timed_out": false,
          "stdout_truncated": false,
          "stderr_truncated": false,
          "future_exec_field": "ignored"
        }
        """
    )

    static let error = """
    {
      "schema_version": 1,
      "request_id": "\(requestID)",
      "kind": "error",
      "data": null,
      "error": {
        "code": "ssh_auth_failed",
        "message_key": "error.ssh.auth_failed",
        "detail_code": "authentication_rejected",
        "retryable": true,
        "request_id": "\(requestID)",
        "challenge_id": null,
        "password": "fixture-must-be-ignored"
      }
    }
    """

    static let persistErrorWithoutRequest = """
    {
      "schema_version": 1,
      "request_id": null,
      "kind": "error",
      "data": null,
      "error": {
        "code": "known_hosts_save_failed",
        "message_key": "error.known_hosts.save_failed",
        "detail_code": "known_hosts_parent_failed",
        "retryable": true,
        "request_id": null,
        "challenge_id": "challenge-fixture-1"
      }
    }
    """

    static let unknownError = error.replacingOccurrences(of: "ssh_auth_failed", with: "future_error_code")
    static let unknownKind = envelope(kind: "future_additive_kind", data: "{\"value\":true}")
    static let unsupportedSchema = connected.replacingOccurrences(of: "\"schema_version\": 1", with: "\"schema_version\": 2")
    static let bothPresent = connected.replacingOccurrences(of: "\"error\": null", with: "\"error\": {\"code\":\"ssh_auth_failed\",\"message_key\":\"error.ssh.auth_failed\",\"detail_code\":null,\"retryable\":true,\"request_id\":\"\(requestID)\",\"challenge_id\":null}")
    static let bothMissing = envelope(kind: "connected", data: "null")

    private static func blocked(reason: String, knownState: String, previous: String, canReplace: Bool) -> String {
        envelope(
            kind: "host_key_blocked",
            data: """
            {
              "host": "fixture.example",
              "normalized_host": "fixture.example",
              "port": 2222,
              "lookup_token": "[fixture.example]:2222",
              "key_algorithm": "ssh-ed25519",
              "presented_fingerprint_sha256": "SHA256:fixturePresented",
              "previous_fingerprint_sha256": \(previous),
              "reason_code": "\(reason)",
              "known_state": "\(knownState)",
              "can_trust": false,
              "can_replace": \(canReplace),
              "message_key": "host_key.\(reason)"
            }
            """
        )
    }

    private static func envelope(kind: String, data: String) -> String {
        """
        {
          "schema_version": 1,
          "request_id": "\(requestID)",
          "kind": "\(kind)",
          "data": \(data),
          "error": null,
          "future_additive_field": "ignored"
        }
        """
    }

    static func data(_ fixture: String) -> Data {
        Data(fixture.utf8)
    }
}
