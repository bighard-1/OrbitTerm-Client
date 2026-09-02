import Foundation

/// The diagnostic export is intentionally a small, schema-bound data set.  It
/// must never become a second copy of request URLs or server-provided errors.
enum DiagnosticEndpoint: String, Codable, Sendable {
    case authentication
    case account
    case configuration
    case synchronization
    case unknown

    static func classify(url: String) -> Self {
        guard let path = URLComponents(string: url)?.path else { return .unknown }
        switch path {
        case "/api/v1/auth/register", "/api/v1/auth/login", "/api/v1/auth/refresh":
            return .authentication
        case "/api/v1/auth/password":
            return .account
        case "/api/v1/config/sync/pull", "/api/v1/config/sync/ack":
            return .synchronization
        default:
            return path.hasPrefix("/api/v1/config/") ? .configuration : .unknown
        }
    }
}

enum DiagnosticFailureKind: String, Codable, Sendable {
    case transport
    case serverRetry
    case response
    case unknown

    /// This deliberately returns only a reviewed category.  Raw NSError and
    /// server text are never eligible diagnostic fields.
    static func classify(_ raw: String?) -> Self? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw == "server_5xx_retry" { return .serverRetry }
        if raw.contains("URLError") || raw.contains("NSURLError") { return .transport }
        return .unknown
    }
}

/// Aggregate-only sync lifecycle events. Values are fixed at compile time and
/// can never contain an account, asset, request identity, endpoint, or error.
enum SyncDiagnosticEvent: String, Codable, CaseIterable, Sendable {
    case unknownResultQueued = "unknown_result_queued"
    case deliveryDeferred = "delivery_deferred"
    case deliveryBlocked = "delivery_blocked"
    case idempotentReplayConfirmed = "idempotent_replay_confirmed"
}

enum DiagnosticsPrivacy {
    static func exportLine(
        timestamp: String,
        method: String,
        endpoint: DiagnosticEndpoint,
        statusCode: Int?,
        latencyMs: Int,
        attempt: Int,
        failure: DiagnosticFailureKind?
    ) -> String {
        let code = statusCode.map(String.init) ?? "-"
        let failureValue = failure?.rawValue ?? "-"
        return "[\(timestamp)] method=\(method) endpoint=\(endpoint.rawValue) status=\(code) latency_ms=\(latencyMs) attempt=\(attempt) failure=\(failureValue)"
    }

    static func syncEventExportLine(_ event: SyncDiagnosticEvent, count: Int) -> String {
        "sync_event=\(event.rawValue) count=\(max(0, count))"
    }
}

/// Names and retention rules for the intentionally small diagnostic artifact.
/// Keeping this policy pure makes the export boundary reviewable without giving
/// tests access to the diagnostics manager or any application state.
enum DiagnosticExportFilePolicy {
    static let filenamePrefix = "orbitterm_diagnostics_"
    static let filenameExtension = "txt"
    static let retention: TimeInterval = 15 * 60

    static func filename(for id: UUID = UUID()) -> String {
        "\(filenamePrefix)\(id.uuidString.lowercased()).\(filenameExtension)"
    }

    static func isManagedFilename(_ filename: String) -> Bool {
        guard filename.hasPrefix(filenamePrefix),
              filename.hasSuffix(".\(filenameExtension)") else {
            return false
        }

        let identifier = filename
            .dropFirst(filenamePrefix.count)
            .dropLast(filenameExtension.count + 1)
        return UUID(uuidString: String(identifier)) != nil
    }

    static func isExpired(modificationDate: Date, now: Date) -> Bool {
        now.timeIntervalSince(modificationDate) >= retention
    }
}
