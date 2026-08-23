import CryptoKit
import Foundation
import Network
import SQLite3
import os

enum SyncQueueOperation: Codable {
    case upload(UploadConfigRequest)
    case delete(assetID: UUID, request: AssetMutationRequest)
    case restore(assetID: UUID, request: AssetMutationRequest)
    case purge(assetID: UUID, request: AssetMutationRequest)
}

struct SyncQueueItem: Codable, Identifiable {
    let id: UUID
    /// Opaque account namespace. Queued work is never sent using another account's token.
    let accountIdentifier: String
    let operation: SyncQueueOperation
    let requestHash: String
    let createdAt: Date
    var updatedAt: Date
    var attemptCount: Int
    var nextRetryAt: Date
    var lastError: String?

    init(
        id: UUID = UUID(),
        accountIdentifier: String,
        operation: SyncQueueOperation,
        requestHash: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        attemptCount: Int = 0,
        nextRetryAt: Date = Date(),
        lastError: String? = nil
    ) {
        self.id = id
        self.accountIdentifier = accountIdentifier
        self.operation = operation
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
        (id, account_identifier, request_hash, payload_json, created_at, updated_at, attempt_count, next_retry_at, last_error)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        let payloadData = (try? JSONEncoder().encode(item.operation)) ?? Data()
        let payloadText = String(data: payloadData, encoding: .utf8) ?? "{}"
        bindText(item.id.uuidString, stmt: stmt, index: 1)
        bindText(item.accountIdentifier, stmt: stmt, index: 2)
        bindText(item.requestHash, stmt: stmt, index: 3)
        bindText(payloadText, stmt: stmt, index: 4)
        sqlite3_bind_double(stmt, 5, item.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 6, item.updatedAt.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 7, Int32(item.attemptCount))
        sqlite3_bind_double(stmt, 8, item.nextRetryAt.timeIntervalSince1970)
        if let lastError = item.lastError {
            bindText(lastError, stmt: stmt, index: 9)
        } else {
            sqlite3_bind_null(stmt, 9)
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

    func firstItem(accountIdentifier: String) -> SyncQueueItem? {
        guard let db else { return nil }
        let sql = """
        SELECT id, account_identifier, request_hash, payload_json, created_at, updated_at, attempt_count, next_retry_at, last_error
        FROM sync_queue
        WHERE account_identifier = ?
        ORDER BY created_at ASC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(accountIdentifier, stmt: stmt, index: 1)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        guard let idText = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let id = UUID(uuidString: idText),
              let itemAccountIdentifier = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
              let hashText = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
              let payloadText = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
              let payloadData = payloadText.data(using: .utf8),
              let operation = Self.decodeOperation(payloadData) else {
            return nil
        }
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        let attemptCount = Int(sqlite3_column_int(stmt, 6))
        let nextRetryAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        let lastError = sqlite3_column_text(stmt, 8).map { String(cString: $0) }

        return SyncQueueItem(
            id: id,
            accountIdentifier: itemAccountIdentifier,
            operation: operation,
            requestHash: hashText,
            createdAt: createdAt,
            updatedAt: updatedAt,
            attemptCount: attemptCount,
            nextRetryAt: nextRetryAt,
            lastError: lastError
        )
    }

    private static func decodeOperation(_ data: Data) -> SyncQueueOperation? {
        if let operation = try? JSONDecoder().decode(SyncQueueOperation.self, from: data) {
            return operation
        }
        // SQLite v1 仅保存 UploadConfigRequest，升级时原位兼容读取。
        if let legacyUpload = try? JSONDecoder().decode(UploadConfigRequest.self, from: data) {
            return .upload(legacyUpload)
        }
        return nil
    }

    private static func createTableIfNeeded(db: OpaquePointer?) {
        guard let db else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS sync_queue (
            id TEXT PRIMARY KEY NOT NULL,
            account_identifier TEXT NULL,
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
        _ = sqlite3_exec(db, "ALTER TABLE sync_queue ADD COLUMN account_identifier TEXT NULL;", nil, nil, nil)
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS sync_queue_account_created ON sync_queue(account_identifier, created_at);", nil, nil, nil)
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

struct SyncQueueAuthContext {
    let token: String
    let accountIdentifier: String
}

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
    private var wakeGeneration: UUID?
    private var processingOwner = OperationOwner()
    private var authContextProvider: (() -> SyncQueueAuthContext?)?

    private let store: SyncQueueStore

    private init() {
        let dbURL = Self.queueDBURL()
        self.store = SyncQueueStore(fileURL: dbURL)
        migrateLegacyJSONIfNeeded()
        startMonitor()
    }

    func setAuthContextProvider(_ provider: @escaping () -> SyncQueueAuthContext?) {
        stateQueue.sync {
            authContextProvider = provider
        }
        triggerProcessing(reason: "token_provider_updated")
    }

    /// Stops queue delivery without removing persisted work. A later unlock or
    /// foreground activation may resume it with the same account-scoped queue.
    /// Any in-flight response is ignored after this point.
    func suspendProcessing() {
        stateQueue.sync {
            processingOwner.invalidate()
            processingTask?.cancel()
            processingTask = nil
            wakeTask?.cancel()
            wakeTask = nil
            wakeGeneration = nil
        }
    }

    func resumeProcessing() {
        triggerProcessing(reason: "operation_lifecycle_resumed")
    }

    func enqueueUpload(payload: UploadConfigRequest, accountID: String, reason: String?) async {
        await enqueue(.upload(payload), accountID: accountID, reason: reason)
    }

    func enqueueDelete(assetID: UUID, request: AssetMutationRequest, accountID: String, reason: String?) async {
        await enqueue(.delete(assetID: assetID, request: request), accountID: accountID, reason: reason)
    }

    func enqueueRestore(assetID: UUID, request: AssetMutationRequest, accountID: String, reason: String?) async {
        await enqueue(.restore(assetID: assetID, request: request), accountID: accountID, reason: reason)
    }

    func enqueuePurge(assetID: UUID, request: AssetMutationRequest, accountID: String, reason: String?) async {
        await enqueue(.purge(assetID: assetID, request: request), accountID: accountID, reason: reason)
    }

    private func enqueue(_ operation: SyncQueueOperation, accountID: String, reason: String?) async {
        guard let scope = AccountScope(username: accountID) else { return }
        let hash = Self.requestHash(operation, accountIdentifier: scope.storageIdentifier)
        let item = SyncQueueItem(
            accountIdentifier: scope.storageIdentifier,
            operation: operation,
            requestHash: hash,
            attemptCount: 0,
            nextRetryAt: Date(),
            lastError: reason
        )
        await store.append(item)
        logger.debug("[SYNCQ] enqueue id=\(item.id.uuidString, privacy: .private(mask: .hash))")
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
            // A direct trigger supersedes any scheduled retry wake. The current
            // queue head is checked again by processLoop, so no retry is lost.
            wakeTask?.cancel()
            wakeTask = nil
            wakeGeneration = nil

            let activeDeliveries = processingTask == nil ? 0 : 1
            let canStart = isNetworkReachable &&
                OperationResourceBudget.permitsSyncDelivery(activeDeliveries: activeDeliveries)
            guard canStart else { return }
            guard let auth = authContextProvider?(), !auth.token.isEmpty else { return }
            let accountIdentifier = auth.accountIdentifier
            let lease = processingOwner.begin(scope: .account(accountIdentifier))
            processingTask = Task(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.processLoop(
                    reason: reason,
                    accountIdentifier: accountIdentifier,
                    lease: lease
                )
                self.stateQueue.sync {
                    guard self.ownsProcessingLease(lease, accountIdentifier: accountIdentifier) else { return }
                    self.processingTask = nil
                }
            }
        }
    }

    private func processLoop(
        reason: String,
        accountIdentifier: String,
        lease: OperationLease
    ) async {
        logger.debug("[SYNCQ] process start reason=\(reason, privacy: .private(mask: .hash))")
        while !Task.isCancelled {
            guard ownsProcessingLease(lease, accountIdentifier: accountIdentifier) else { return }
            guard isNetworkUp else { return }
            guard let auth = currentAuthContext(),
                  !auth.token.isEmpty,
                  auth.accountIdentifier == accountIdentifier else {
                logger.debug("[SYNCQ] process paused: token unavailable")
                return
            }
            guard let head = await store.firstItem(accountIdentifier: accountIdentifier) else {
                logger.debug("[SYNCQ] queue empty")
                return
            }

            if head.nextRetryAt > Date() {
                scheduleWake(
                    at: head.nextRetryAt,
                    processingLease: lease,
                    accountIdentifier: accountIdentifier
                )
                return
            }

            do {
                try await send(head.operation, token: auth.token)
                guard !Task.isCancelled,
                      ownsProcessingLease(lease, accountIdentifier: accountIdentifier),
                      currentAuthContext()?.accountIdentifier == accountIdentifier else {
                    return
                }
                await store.remove(id: head.id)
                logger.debug("[SYNCQ] sent id=\(head.id.uuidString, privacy: .private(mask: .hash))")
            } catch {
                guard !Task.isCancelled,
                      ownsProcessingLease(lease, accountIdentifier: accountIdentifier),
                      currentAuthContext()?.accountIdentifier == accountIdentifier else {
                    return
                }
                if let net = error as? NetworkService.NetworkError,
                   case .unauthorized = net {
                    logger.debug("[SYNCQ] paused: auth expired")
                    return
                }
                var failed = head
                failed.attemptCount += 1
                failed.updatedAt = Date()
                failed.lastError = OperationRecoveryMapper.sync(error).diagnosticCode
                failed.nextRetryAt = Date().addingTimeInterval(Self.backoffSeconds(for: failed.attemptCount))
                await store.update(failed)
                logger.debug("[SYNCQ] retry id=\(failed.id.uuidString, privacy: .private(mask: .hash)) attempt=\(failed.attemptCount)")
                scheduleWake(
                    at: failed.nextRetryAt,
                    processingLease: lease,
                    accountIdentifier: accountIdentifier
                )
                return
            }
        }
    }

    private func send(_ operation: SyncQueueOperation, token: String) async throws {
        switch operation {
        case let .upload(payload):
            _ = try await network.uploadConfig(token: token, payload: payload)
        case let .delete(assetID, request):
            _ = try await network.moveAssetToTrash(assetID: assetID, request: request)
        case let .restore(assetID, request):
            _ = try await network.restoreAsset(assetID: assetID, request: request)
        case let .purge(assetID, request):
            _ = try await network.purgeAsset(assetID: assetID, request: request)
        }
    }

    private func scheduleWake(
        at date: Date,
        processingLease: OperationLease,
        accountIdentifier: String
    ) {
        let generation = UUID()
        stateQueue.sync {
            guard ownsProcessingLease(processingLease, accountIdentifier: accountIdentifier) else { return }
            wakeTask?.cancel()
            wakeTask = nil
            wakeGeneration = generation
        }

        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let sleepNanos = max(0, date.timeIntervalSinceNow) * 1_000_000_000
            if sleepNanos > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(sleepNanos))
                } catch {
                    return
                }
            }

            guard self.consumeWake(
                generation: generation,
                processingLease: processingLease,
                accountIdentifier: accountIdentifier
            ) else { return }
            self.triggerProcessing(reason: "backoff_elapsed")
        }
        stateQueue.sync {
            // The task can run immediately for an already-due retry. In that
            // case it has already consumed this generation and must not be
            // reinstalled as a stale wake.
            guard wakeGeneration == generation,
                  ownsProcessingLease(processingLease, accountIdentifier: accountIdentifier) else {
                task.cancel()
                return
            }
            wakeTask = task
        }
    }

    /// Atomically consumes the one retry wake that is still current. A
    /// cancelled or superseded wake can never start a later queue run.
    private func consumeWake(
        generation: UUID,
        processingLease: OperationLease,
        accountIdentifier: String
    ) -> Bool {
        stateQueue.sync {
            guard wakeGeneration == generation,
                  ownsProcessingLease(processingLease, accountIdentifier: accountIdentifier) else { return false }
            wakeGeneration = nil
            wakeTask = nil
            return true
        }
    }

    private var isNetworkUp: Bool {
        stateQueue.sync { isNetworkReachable }
    }

    private func ownsProcessingLease(
        _ lease: OperationLease,
        accountIdentifier: String
    ) -> Bool {
        processingOwner.owns(lease, scope: .account(accountIdentifier))
    }

    private func currentAuthContext() -> SyncQueueAuthContext? {
        stateQueue.sync { authContextProvider?() }
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
                let operation = SyncQueueOperation.upload(item.payload)
                let hash = Self.requestHash(operation, accountIdentifier: "legacy-unassigned")
                let migrated = SyncQueueItem(
                    id: item.id,
                    accountIdentifier: "legacy-unassigned",
                    operation: operation,
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

    private static func requestHash(_ operation: SyncQueueOperation, accountIdentifier: String) -> String {
        if case let .upload(payload) = operation {
            // 保持与 SQLite v1 相同的哈希，升级时不会重复入队已有上传任务。
            let legacyBase = "\(accountIdentifier)|\(payload.id ?? 0)|\(payload.vector_clock)|\(payload.encrypted_blob_base64)"
            let digest = SHA256.hash(data: Data(legacyBase.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(operation)) ?? Data()
        let digest = SHA256.hash(data: Data(accountIdentifier.utf8) + encoded)
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
