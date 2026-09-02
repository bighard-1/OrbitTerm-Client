import Foundation

struct DiagnosticEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let method: String
    let endpoint: DiagnosticEndpoint
    let statusCode: Int?
    let latencyMs: Int
    let failure: DiagnosticFailureKind?
    let attempt: Int
}

@MainActor
final class DiagnosticsManager: ObservableObject {
    static let shared = DiagnosticsManager()
    private static let capacity = 50

    @Published private(set) var entries: [DiagnosticEntry] = []
    @Published private(set) var retryInFlightCount: Int = 0
    @Published private(set) var syncEventCounts: [SyncDiagnosticEvent: Int] = [:]
    private var exportCleanupTasks: [URL: Task<Void, Never>] = [:]

    private(set) var activeAccountScope: AccountScope?

    init() {}

    /// Diagnostics are account-scoped presentation data. Switching accounts
    /// never carries prior request history into the new account's export.
    func activateAccount(username: String) {
        let nextScope = AccountScope(username: username)
        guard activeAccountScope != nextScope else { return }
        discardAllExports()
        entries = []
        retryInFlightCount = 0
        syncEventCounts = [:]
        activeAccountScope = nextScope
    }

    func deactivateAccount() {
        discardAllExports()
        entries = []
        retryInFlightCount = 0
        syncEventCounts = [:]
        activeAccountScope = nil
    }

    var isRetrying: Bool {
        retryInFlightCount > 0
    }

    func beginRetry() {
        retryInFlightCount += 1
    }

    func endRetry() {
        retryInFlightCount = max(0, retryInFlightCount - 1)
    }

    func recordSyncEvent(_ event: SyncDiagnosticEvent) {
        syncEventCounts[event, default: 0] += 1
    }

    func record(
        method: String,
        url: String,
        statusCode: Int?,
        latencyMs: Int,
        errorType: String?,
        attempt: Int
    ) {
        let item = DiagnosticEntry(
            id: UUID(),
            timestamp: Date(),
            method: method,
            endpoint: DiagnosticEndpoint.classify(url: url),
            statusCode: statusCode,
            latencyMs: latencyMs,
            failure: DiagnosticFailureKind.classify(errorType),
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
            DiagnosticsPrivacy.exportLine(
                timestamp: iso.string(from: item.timestamp),
                method: item.method,
                endpoint: item.endpoint,
                statusCode: item.statusCode,
                latencyMs: item.latencyMs,
                attempt: item.attempt,
                failure: item.failure
            )
        }
        let syncLines = SyncDiagnosticEvent.allCases.compactMap { event -> String? in
            guard let count = syncEventCounts[event], count > 0 else { return nil }
            return DiagnosticsPrivacy.syncEventExportLine(event, count: count)
        }
        return (lines + syncLines).joined(separator: "\n")
    }

    func exportToTempFile() throws -> URL {
        removeExpiredExports()

        let content = exportText()
        let base = FileManager.default.temporaryDirectory
        let file = base.appendingPathComponent(DiagnosticExportFilePolicy.filename())
        guard let data = content.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        scheduleExportCleanup(for: file)
        return file
    }

    /// Removes only a file created by this manager. This is safe to call when
    /// the export sheet closes and never touches another app's temporary file.
    func discardExport(_ file: URL) {
        guard isManagedExport(file) else { return }
        exportCleanupTasks.removeValue(forKey: file)?.cancel()
        try? FileManager.default.removeItem(at: file)
    }

    private func discardAllExports() {
        let files = Array(exportCleanupTasks.keys)
        for file in files {
            discardExport(file)
        }
    }

    private func removeExpiredExports(now: Date = Date()) {
        let base = FileManager.default.temporaryDirectory
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for file in files where isManagedExport(file) {
            let values = try? file.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true,
                  let date = values?.contentModificationDate,
                  DiagnosticExportFilePolicy.isExpired(modificationDate: date, now: now) else {
                continue
            }
            discardExport(file)
        }
    }

    private func isManagedExport(_ file: URL) -> Bool {
        let base = FileManager.default.temporaryDirectory.standardizedFileURL
        let parent = file.deletingLastPathComponent().standardizedFileURL
        return parent == base && DiagnosticExportFilePolicy.isManagedFilename(file.lastPathComponent)
    }

    private func scheduleExportCleanup(for file: URL) {
        exportCleanupTasks.removeValue(forKey: file)?.cancel()
        exportCleanupTasks[file] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(DiagnosticExportFilePolicy.retention * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.discardExport(file)
        }
    }
}

extension DiagnosticsManager: AccountScopedPresentationService {}
