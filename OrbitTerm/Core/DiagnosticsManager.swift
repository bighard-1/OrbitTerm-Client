import Foundation

struct DiagnosticEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let method: String
    let url: String
    let statusCode: Int?
    let latencyMs: Int
    let errorType: String?
    let attempt: Int
}

@MainActor
final class DiagnosticsManager: ObservableObject {
    static let shared = DiagnosticsManager()
    private static let capacity = 50

    @Published private(set) var entries: [DiagnosticEntry] = []
    @Published private(set) var retryInFlightCount: Int = 0

    private init() {}

    var isRetrying: Bool {
        retryInFlightCount > 0
    }

    func beginRetry() {
        retryInFlightCount += 1
    }

    func endRetry() {
        retryInFlightCount = max(0, retryInFlightCount - 1)
    }

    func record(
        method: String,
        url: String,
        statusCode: Int?,
        latencyMs: Int,
        errorType: String?,
        attempt: Int
    ) {
        let cleanURL = sanitizeURL(url)
        let cleanError = sanitizeError(errorType)
        let item = DiagnosticEntry(
            id: UUID(),
            timestamp: Date(),
            method: method,
            url: cleanURL,
            statusCode: statusCode,
            latencyMs: latencyMs,
            errorType: cleanError,
            attempt: attempt
        )
        entries.append(item)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    func exportText() -> String {
        let iso = ISO8601DateFormatter()
        let lines = entries.map { item -> String in
            let code = item.statusCode.map(String.init) ?? "-"
            let err = item.errorType ?? "-"
            return "[\(iso.string(from: item.timestamp))] \(item.method) \(item.url) status=\(code) latency_ms=\(item.latencyMs) attempt=\(item.attempt) error=\(err)"
        }
        return lines.joined(separator: "\n")
    }

    func exportToTempFile() throws -> URL {
        let content = exportText()
        let base = FileManager.default.temporaryDirectory
        let file = base.appendingPathComponent("orbitterm_diagnostics_\(Int(Date().timeIntervalSince1970)).txt")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func sanitizeURL(_ raw: String) -> String {
        guard var comp = URLComponents(string: raw) else { return raw }
        if let items = comp.queryItems, !items.isEmpty {
            comp.queryItems = items.map { item in
                let lower = item.name.lowercased()
                if lower.contains("password") || lower.contains("token") || lower.contains("private") || lower.contains("key") || lower.contains("authorization") {
                    return URLQueryItem(name: item.name, value: "***")
                }
                return item
            }
        }
        return comp.string ?? raw
    }

    private func sanitizeError(_ raw: String?) -> String? {
        guard var text = raw, !text.isEmpty else { return nil }
        let patterns = ["authorization", "password", "private_key", "privatekey", "token", "bearer"]
        for p in patterns {
            if text.lowercased().contains(p) {
                text = "redacted"
                break
            }
        }
        return text
    }
}

