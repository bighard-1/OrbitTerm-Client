import Foundation
import SQLite3

struct Snippet: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var command: String
    var category: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        command: String,
        category: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.category = category
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

private struct SnippetSyncEnvelope: Codable {
    let kind: String
    let version: Int
    let updatedAtUnix: Int
    let snippets: [Snippet]

    static let marker = "orbit_snippets"

    init(updatedAtUnix: Int, snippets: [Snippet]) {
        self.kind = Self.marker
        self.version = 1
        self.updatedAtUnix = updatedAtUnix
        self.snippets = snippets
    }
}

private struct SnippetRemoteCandidate {
    let envelope: SnippetSyncEnvelope
    let configID: UInt
    let vectorClock: String
}

private actor SnippetStoreDB {
    private let db: OpaquePointer?

    init(fileURL: URL) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var raw: OpaquePointer?
        sqlite3_open(fileURL.path, &raw)
        db = raw
        if let db {
            let sql = """
            CREATE TABLE IF NOT EXISTS snippets (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                command TEXT NOT NULL,
                category TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS snippets_meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            """
            _ = sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func loadAll() -> [Snippet] {
        guard let db else { return [] }

        let sql = """
        SELECT id, title, command, category, created_at, updated_at
        FROM snippets
        ORDER BY updated_at DESC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var items: [Snippet] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let id = UUID(uuidString: idText),
                  let title = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let command = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
                  let category = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }) else {
                continue
            }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            items.append(
                Snippet(
                    id: id,
                    title: title,
                    command: command,
                    category: category,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }
        return items
    }

    func upsert(_ snippet: Snippet) {
        guard let db else { return }
        let sql = """
        INSERT INTO snippets (id, title, command, category, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            command = excluded.command,
            category = excluded.category,
            updated_at = excluded.updated_at;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return
        }
        defer { sqlite3_finalize(stmt) }

        bindText(snippet.id.uuidString, stmt: stmt, index: 1)
        bindText(snippet.title, stmt: stmt, index: 2)
        bindText(snippet.command, stmt: stmt, index: 3)
        bindText(snippet.category, stmt: stmt, index: 4)
        sqlite3_bind_double(stmt, 5, snippet.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 6, snippet.updatedAt.timeIntervalSince1970)

        _ = sqlite3_step(stmt)
    }

    func remove(id: UUID) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM snippets WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return
        }
        defer { sqlite3_finalize(stmt) }
        bindText(id.uuidString, stmt: stmt, index: 1)
        _ = sqlite3_step(stmt)
    }

    func replaceAll(_ snippets: [Snippet]) {
        guard let db else { return }
        _ = sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil)
        defer { _ = sqlite3_exec(db, "COMMIT;", nil, nil, nil) }

        _ = sqlite3_exec(db, "DELETE FROM snippets;", nil, nil, nil)
        for snippet in snippets {
            upsert(snippet)
        }
    }

    func readMeta(_ key: String) -> String? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM snippets_meta WHERE key = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        bindText(key, stmt: stmt, index: 1)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let value = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else {
            return nil
        }
        return value
    }

    func writeMeta(_ key: String, value: String) {
        guard let db else { return }
        let sql = """
        INSERT INTO snippets_meta (key, value)
        VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return
        }
        defer { sqlite3_finalize(stmt) }

        bindText(key, stmt: stmt, index: 1)
        bindText(value, stmt: stmt, index: 2)
        _ = sqlite3_step(stmt)
    }

    private func createTablesIfNeeded() {
        guard let db else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS snippets (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            command TEXT NOT NULL,
            category TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS snippets_meta (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """
        _ = sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func bindText(_ text: String, stmt: OpaquePointer, index: Int32) {
        _ = text.withCString { cstr in
            sqlite3_bind_text(stmt, index, cstr, -1, SQLITE_TRANSIENT)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@MainActor
final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()

    @Published private(set) var snippets: [Snippet] = []
    @Published var lastSyncMessage: String = "Snippets 未同步"

    private let db: SnippetStoreDB
    private let network = NetworkService.shared
    private let orbitManager = OrbitManager()

    private enum MetaKey {
        static let remoteConfigID = "snippet_remote_config_id"
        static let vectorClock = "snippet_vector_clock"
        static let envelopeTime = "snippet_envelope_time"
    }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dbURL = base
            .appendingPathComponent("OrbitTerm", isDirectory: true)
            .appendingPathComponent("snippets.sqlite", isDirectory: false)
        self.db = SnippetStoreDB(fileURL: dbURL)

        Task { [weak self] in
            await self?.reloadFromDB()
        }
    }

    func filteredSnippets(query: String) -> [Snippet] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return snippets }
        return snippets.filter {
            $0.title.localizedCaseInsensitiveContains(q) ||
                $0.command.localizedCaseInsensitiveContains(q) ||
                $0.category.localizedCaseInsensitiveContains(q)
        }
    }

    func addSnippet(
        title: String,
        command: String,
        category: String,
        token: String?,
        masterPassword: String?
    ) async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedCommand.isEmpty else { return }

        let snippet = Snippet(
            title: trimmedTitle,
            command: trimmedCommand,
            category: trimmedCategory.isEmpty ? "未分类" : trimmedCategory
        )
        await db.upsert(snippet)
        await reloadFromDB()
        await syncIfPossible(token: token, masterPassword: masterPassword, reason: "create")
    }

    func updateSnippet(
        _ snippet: Snippet,
        title: String,
        command: String,
        category: String,
        token: String?,
        masterPassword: String?
    ) async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedCommand.isEmpty else { return }

        var updated = snippet
        updated.title = trimmedTitle
        updated.command = trimmedCommand
        updated.category = trimmedCategory.isEmpty ? "未分类" : trimmedCategory
        updated.updatedAt = Date()

        await db.upsert(updated)
        await reloadFromDB()
        await syncIfPossible(token: token, masterPassword: masterPassword, reason: "update")
    }

    func deleteSnippet(
        _ snippet: Snippet,
        token: String?,
        masterPassword: String?
    ) async {
        await db.remove(id: snippet.id)
        await reloadFromDB()
        await syncIfPossible(token: token, masterPassword: masterPassword, reason: "delete")
    }

    func quickSaveFromHistory(
        command: String,
        token: String?,
        masterPassword: String?
    ) async {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let pieces = trimmed.split(separator: " ").prefix(3).map(String.init)
        let title = pieces.isEmpty ? "新片段" : pieces.joined(separator: " ")
        await addSnippet(
            title: title,
            command: trimmed,
            category: "历史",
            token: token,
            masterPassword: masterPassword
        )
    }

    func pullFromCloud(token: String?, masterPassword: String?) async {
        guard let token, let masterPassword else { return }
        do {
            let remoteItems = try await network.pullConfigs(token: token)
            guard !remoteItems.isEmpty else {
                lastSyncMessage = "Snippets 拉取完成（云端为空）"
                return
            }

            guard let latest = await latestSnippetEnvelopeBackground(remoteItems, masterPassword: masterPassword) else {
                lastSyncMessage = "Snippets 拉取完成（未发现 Snippet 数据）"
                return
            }

            let localEnvelopeTime = Int(await db.readMeta(MetaKey.envelopeTime) ?? "0") ?? 0
            if latest.envelope.updatedAtUnix >= localEnvelopeTime {
                await db.replaceAll(latest.envelope.snippets)
                await db.writeMeta(MetaKey.remoteConfigID, value: String(latest.configID))
                await db.writeMeta(MetaKey.vectorClock, value: latest.vectorClock)
                await db.writeMeta(MetaKey.envelopeTime, value: String(latest.envelope.updatedAtUnix))
                await reloadFromDB()
                lastSyncMessage = "Snippets 已拉取并应用 \(latest.envelope.snippets.count) 条"
            } else {
                lastSyncMessage = "Snippets 已是最新"
            }
        } catch {
            lastSyncMessage = "Snippets 拉取失败: \(error.localizedDescription)"
        }
    }

    private nonisolated func latestSnippetEnvelopeBackground(
        _ remoteItems: [UploadConfigData],
        masterPassword: String
    ) async -> SnippetRemoteCandidate? {
        await Task.detached(priority: .utility) {
            var latest: SnippetRemoteCandidate?

            for item in remoteItems {
                guard let blobData = Data(base64Encoded: item.encrypted_blob_base64),
                      let plain = try? Self.decryptBlob(password: masterPassword, encrypted: blobData),
                      let text = String(data: plain, encoding: .utf8),
                      let data = text.data(using: .utf8),
                      let env = try? JSONDecoder().decode(SnippetSyncEnvelope.self, from: data),
                      env.kind == SnippetSyncEnvelope.marker else {
                    continue
                }

                if latest == nil || env.updatedAtUnix > (latest?.envelope.updatedAtUnix ?? 0) {
                    latest = SnippetRemoteCandidate(
                        envelope: env,
                        configID: item.id,
                        vectorClock: item.vector_clock
                    )
                }
            }

            return latest
        }.value
    }

    private nonisolated static func decryptBlob(password: String, encrypted: Data) throws -> Data {
        guard let passwordCString = password.cString(using: .utf8) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        let encryptedB64 = encrypted.base64EncodedString()
        guard let encryptedCString = encryptedB64.cString(using: .utf8),
              let resultPtr = orbit_decrypt_config(passwordCString, encryptedCString) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        defer { orbit_free_string(resultPtr) }
        let raw = String(cString: resultPtr)
        guard raw.hasPrefix("OK:"),
              let decoded = Data(base64Encoded: String(raw.dropFirst(3))) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        return decoded
    }

    private func syncIfPossible(token: String?, masterPassword: String?, reason: String) async {
        guard let token, let masterPassword else {
            lastSyncMessage = "Snippets 已本地保存，登录后自动同步"
            return
        }

        // 首次同步前先尝试拉取一次远端 ID，避免在离线恢复后重复创建多条 Snippet 配置记录。
        if await db.readMeta(MetaKey.remoteConfigID) == nil {
            await pullFromCloud(token: token, masterPassword: masterPassword)
        }

        guard let payload = try? await buildUploadPayload(masterPassword: masterPassword) else {
            lastSyncMessage = "Snippets 同步失败: 无法构建加密负载"
            return
        }

        do {
            let response = try await network.uploadConfig(token: token, payload: payload)
            await db.writeMeta(MetaKey.remoteConfigID, value: String(response.id))
            await db.writeMeta(MetaKey.vectorClock, value: response.vector_clock)
            lastSyncMessage = "Snippets 已同步（\(reason)）"
        } catch {
            if NetworkService.isRetriableNetworkError(error) {
                await SyncQueue.shared.enqueueUpload(payload: payload, reason: "snippets_\(reason)")
                lastSyncMessage = "网络波动，Snippets 已加入重试队列"
                return
            }
            lastSyncMessage = "Snippets 同步失败: \(error.localizedDescription)"
        }
    }

    private func buildUploadPayload(masterPassword: String) async throws -> UploadConfigRequest {
        let current = await db.loadAll()
        let envelopeTime = max(Int(Date().timeIntervalSince1970), Int(current.map(\.updatedAt).map(\.timeIntervalSince1970).max() ?? Date().timeIntervalSince1970))
        let envelope = SnippetSyncEnvelope(updatedAtUnix: envelopeTime, snippets: current)
        let plainData = try JSONEncoder().encode(envelope)
        guard let plainText = String(data: plainData, encoding: .utf8) else {
            throw NetworkService.NetworkError.decodeFailed
        }

        let encrypted = try orbitManager.encrypt(password: masterPassword, data: plainText)

        let previousID = await db.readMeta(MetaKey.remoteConfigID)
        let idValue = previousID.flatMap(UInt.init)
        let existingClock = await db.readMeta(MetaKey.vectorClock) ?? "{}"
        let nextClock = bumpedVectorClock(from: existingClock)

        await db.writeMeta(MetaKey.vectorClock, value: nextClock)
        await db.writeMeta(MetaKey.envelopeTime, value: String(envelopeTime))

        return UploadConfigRequest(
            id: idValue,
            encrypted_blob_base64: encrypted.base64EncodedString(),
            vector_clock: nextClock
        )
    }

    private func bumpedVectorClock(from raw: String) -> String {
        var map = (try? JSONDecoder().decode([String: Int].self, from: Data(raw.utf8))) ?? [:]
        map["snippet_client"] = (map["snippet_client"] ?? 0) + 1
        let data = (try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func reloadFromDB() async {
        let loaded = await db.loadAll()
        snippets = loaded
    }
}
