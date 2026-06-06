import CryptoKit
import Foundation
import Network
import SQLite3
import os

struct SyncQueueItem: Codable, Identifiable {
    let id: UUID
    let payload: UploadConfigRequest
    let requestHash: String
    let createdAt: Date
    var updatedAt: Date
    var attemptCount: Int
    var nextRetryAt: Date
    var lastError: String?

    init(
        id: UUID = UUID(),
        payload: UploadConfigRequest,
        requestHash: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        attemptCount: Int = 0,
        nextRetryAt: Date = Date(),
        lastError: String? = nil
    ) {
        self.id = id
        self.payload = payload
        self.requestHash = requestHash
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.attemptCount = attemptCount
        self.nextRetryAt = nextRetryAt
        self.lastError = lastError
    }
}

actor SyncQueueStore {
    private let db: OpaquePointer?
    private let queueDBURL: URL

    init(fileURL: URL) {
        self.queueDBURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var raw: OpaquePointer?
        sqlite3_open(fileURL.path, &raw)
        db = raw
        Self.createTableIfNeeded(db: raw)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func append(_ item: SyncQueueItem) {
        guard let db else { return }
        _ = execute(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        defer { _ = execute(db, sql: "COMMIT;") }

        let sql = """
        INSERT OR IGNORE INTO sync_queue
        (id, request_hash, payload_json, created_at, updated_at, attempt_count, next_retry_at, last_error)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        let payloadData = (try? JSONEncoder().encode(item.payload)) ?? Data()
        let payloadText = String(data: payloadData, encoding: .utf8) ?? "{}"
        bindText(item.id.uuidString, stmt: stmt, index: 1)
        bindText(item.requestHash, stmt: stmt, index: 2)
        bindText(payloadText, stmt: stmt, index: 3)
        sqlite3_bind_double(stmt, 4, item.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 5, item.updatedAt.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 6, Int32(item.attemptCount))
        sqlite3_bind_double(stmt, 7, item.nextRetryAt.timeIntervalSince1970)
        if let lastError = item.lastError {
            bindText(lastError, stmt: stmt, index: 8)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        _ = sqlite3_step(stmt)
    }

    func remove(id: UUID) {
        guard let db else { return }
        _ = execute(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        defer { _ = execute(db, sql: "COMMIT;") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM sync_queue WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(id.uuidString, stmt: stmt, index: 1)
        _ = sqlite3_step(stmt)
    }

    func update(_ item: SyncQueueItem) {
        guard let db else { return }
        _ = execute(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        defer { _ = execute(db, sql: "COMMIT;") }

        let sql = "UPDATE sync_queue SET updated_at=?, attempt_count=?, next_retry_at=?, last_error=? WHERE id=?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, item.updatedAt.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 2, Int32(item.attemptCount))
        sqlite3_bind_double(stmt, 3, item.nextRetryAt.timeIntervalSince1970)
        if let lastError = item.lastError {
            bindText(lastError, stmt: stmt, index: 4)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        bindText(item.id.uuidString, stmt: stmt, index: 5)
        _ = sqlite3_step(stmt)
    }

    func firstItem() -> SyncQueueItem? {
        guard let db else { return nil }
        let sql = """
        SELECT id, request_hash, payload_json, created_at, updated_at, attempt_count, next_retry_at, last_error
        FROM sync_queue
        ORDER BY created_at ASC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        guard let idText = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let id = UUID(uuidString: idText),
              let hashText = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
              let payloadText = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
              let payloadData = payloadText.data(using: .utf8),
              let payload = try? JSONDecoder().decode(UploadConfigRequest.self, from: payloadData) else {
            return nil
        }
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        let attemptCount = Int(sqlite3_column_int(stmt, 5))
        let nextRetryAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
        let lastError = sqlite3_column_text(stmt, 7).map { String(cString: $0) }

        return SyncQueueItem(
            id: id,
            payload: payload,
            requestHash: hashText,
            createdAt: createdAt,
            updatedAt: updatedAt,
            attemptCount: attemptCount,
            nextRetryAt: nextRetryAt,
            lastError: lastError
        )
    }

    private static func createTableIfNeeded(db: OpaquePointer?) {
        guard let db else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS sync_queue (
            id TEXT PRIMARY KEY NOT NULL,
            request_hash TEXT NOT NULL UNIQUE,
            payload_json TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            attempt_count INTEGER NOT NULL,
            next_retry_at REAL NOT NULL,
            last_error TEXT NULL
        );
        """
        _ = sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func execute(_ db: OpaquePointer, sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func bindText(_ text: String, stmt: OpaquePointer, index: Int32) {
        _ = text.withCString { cstr in
            sqlite3_bind_text(stmt, index, cstr, -1, SQLITE_TRANSIENT)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SyncQueue {
    static let shared = SyncQueue()

    private let logger = Logger(subsystem: "com.orbitterm.app", category: "sync_queue")
    private let network = NetworkService.shared
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.orbitterm.syncqueue.monitor")
    private let stateQueue = DispatchQueue(label: "com.orbitterm.syncqueue.state")

    private var isNetworkReachable = true
    private var processingTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var authTokenProvider: (() -> String?)?

    private let store: SyncQueueStore

    private init() {
        let dbURL = Self.queueDBURL()
        self.store = SyncQueueStore(fileURL: dbURL)
        migrateLegacyJSONIfNeeded()
        startMonitor()
    }

    func setAuthTokenProvider(_ provider: @escaping () -> String?) {
        stateQueue.sync {
            authTokenProvider = provider
        }
        triggerProcessing(reason: "token_provider_updated")
    }

    func enqueueUpload(payload: UploadConfigRequest, reason: String?) async {
        let hash = Self.requestHash(payload)
        let item = SyncQueueItem(
            payload: payload,
            requestHash: hash,
            attemptCount: 0,
            nextRetryAt: Date(),
            lastError: reason
        )
        await store.append(item)
        logger.debug("[SYNCQ] enqueue id=\(item.id.uuidString, privacy: .public)")
        triggerProcessing(reason: "enqueue")
    }

    private func startMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let available = self.stateQueue.sync { () -> Bool in
                self.isNetworkReachable = (path.status == .satisfied)
                return self.isNetworkReachable
            }
            if available {
                self.triggerProcessing(reason: "network_restored")
            }
        }
        monitor.start(queue: monitorQueue)
    }

    private func triggerProcessing(reason: String) {
        stateQueue.sync {
            let canStart = isNetworkReachable && processingTask == nil
            guard canStart else { return }
            processingTask = Task(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.processLoop(reason: reason)
                self.stateQueue.sync {
                    self.processingTask = nil
                }
            }
        }
    }

    private func processLoop(reason: String) async {
        logger.debug("[SYNCQ] process start reason=\(reason, privacy: .public)")
        while !Task.isCancelled {
            guard isNetworkUp else { return }
            guard let token = currentToken(), !token.isEmpty else {
                logger.debug("[SYNCQ] process paused: token unavailable")
                return
            }
            guard let head = await store.firstItem() else {
                logger.debug("[SYNCQ] queue empty")
                return
            }

            if head.nextRetryAt > Date() {
                scheduleWake(at: head.nextRetryAt)
                return
            }

            do {
                _ = try await network.uploadConfig(token: token, payload: head.payload)
                await store.remove(id: head.id)
                logger.debug("[SYNCQ] sent id=\(head.id.uuidString, privacy: .public)")
            } catch {
                if let net = error as? NetworkService.NetworkError,
                   case .unauthorized = net {
                    logger.debug("[SYNCQ] paused: auth expired")
                    return
                }
                var failed = head
                failed.attemptCount += 1
                failed.updatedAt = Date()
                failed.lastError = error.localizedDescription
                failed.nextRetryAt = Date().addingTimeInterval(Self.backoffSeconds(for: failed.attemptCount))
                await store.update(failed)
                logger.debug("[SYNCQ] retry id=\(failed.id.uuidString, privacy: .public) attempt=\(failed.attemptCount)")
                scheduleWake(at: failed.nextRetryAt)
                return
            }
        }
    }

    private func scheduleWake(at date: Date) {
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let sleepNanos = max(0, date.timeIntervalSinceNow) * 1_000_000_000
            if sleepNanos > 0 {
                try? await Task.sleep(nanoseconds: UInt64(sleepNanos))
            }
            self.triggerProcessing(reason: "backoff_elapsed")
        }
        stateQueue.sync {
            wakeTask?.cancel()
            wakeTask = task
        }
    }

    private var isNetworkUp: Bool {
        stateQueue.sync { isNetworkReachable }
    }

    private func currentToken() -> String? {
        stateQueue.sync { authTokenProvider?() }
    }

    private static func backoffSeconds(for attempt: Int) -> TimeInterval {
        let steps: [TimeInterval] = [10, 30, 120, 300, 600, 900, 1800]
        let index = min(max(0, attempt - 1), steps.count - 1)
        return steps[index]
    }

    private func migrateLegacyJSONIfNeeded() {
        let legacyURL = Self.legacyQueueJSONURL()
        guard let data = try? Data(contentsOf: legacyURL),
              let items = try? JSONDecoder().decode([LegacySyncQueueItem].self, from: data),
              !items.isEmpty else {
            return
        }

        Task {
            for item in items {
                let hash = Self.requestHash(item.payload)
                let migrated = SyncQueueItem(
                    id: item.id,
                    payload: item.payload,
                    requestHash: hash,
                    createdAt: item.createdAt,
                    updatedAt: item.updatedAt,
                    attemptCount: item.attemptCount,
                    nextRetryAt: item.nextRetryAt,
                    lastError: item.lastError
                )
                await store.append(migrated)
            }
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }

    private static func requestHash(_ payload: UploadConfigRequest) -> String {
        let base = "\(payload.id ?? 0)|\(payload.vector_clock)|\(payload.encrypted_blob_base64)"
        let digest = SHA256.hash(data: Data(base.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func queueDBURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("OrbitTerm", isDirectory: true)
            .appendingPathComponent("sync_queue.sqlite", isDirectory: false)
    }

    private static func legacyQueueJSONURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("OrbitTerm", isDirectory: true)
            .appendingPathComponent("sync_queue.json", isDirectory: false)
    }
}

private struct LegacySyncQueueItem: Codable {
    let id: UUID
    let payload: UploadConfigRequest
    let createdAt: Date
    let updatedAt: Date
    let attemptCount: Int
    let nextRetryAt: Date
    let lastError: String?
}
