import Foundation
import SQLite3

struct Snippet: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var command: String
    var category: String
    var assetScope: SnippetAssetScope
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        command: String,
        category: String,
        assetScope: SnippetAssetScope = .allAssets,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.category = category
        self.assetScope = assetScope
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, command, category, assetScope, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        command = try container.decode(String.self, forKey: .command)
        category = try container.decode(String.self, forKey: .category)
        // Envelopes written before asset scoping remain available everywhere.
        assetScope = try container.decodeIfPresent(SnippetAssetScope.self, forKey: .assetScope) ?? .allAssets
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
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
            Self.createTablesIfNeeded(db: db)
            Self.ensureAssetScopeColumn(db: db)
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
        SELECT id, title, command, category, scope_json, created_at, updated_at
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
            let scopeJSON = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
            items.append(
                Snippet(
                    id: id,
                    title: title,
                    command: command,
                    category: category,
                    assetScope: decodeAssetScope(scopeJSON),
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
        INSERT INTO snippets (id, title, command, category, scope_json, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            command = excluded.command,
            category = excluded.category,
            scope_json = excluded.scope_json,
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
        bindText(encodeAssetScope(snippet.assetScope), stmt: stmt, index: 5)
        sqlite3_bind_double(stmt, 6, snippet.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 7, snippet.updatedAt.timeIntervalSince1970)

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

    private static func createTablesIfNeeded(db: OpaquePointer) {
        let sql = """
        CREATE TABLE IF NOT EXISTS snippets (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            command TEXT NOT NULL,
            category TEXT NOT NULL,
            scope_json TEXT NOT NULL DEFAULT '',
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

    private static func ensureAssetScopeColumn(db: OpaquePointer) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(snippets);", -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }

        var hasScopeColumn = false
        while sqlite3_step(statement) == SQLITE_ROW {
            let name = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            if name == "scope_json" {
                hasScopeColumn = true
                break
            }
        }

        guard !hasScopeColumn else { return }
        _ = sqlite3_exec(
            db,
            "ALTER TABLE snippets ADD COLUMN scope_json TEXT NOT NULL DEFAULT '';",
            nil,
            nil,
            nil
        )
    }

    private func encodeAssetScope(_ scope: SnippetAssetScope) -> String {
        guard let data = try? JSONEncoder().encode(scope) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func decodeAssetScope(_ text: String) -> SnippetAssetScope {
        guard !text.isEmpty,
              let data = text.data(using: .utf8),
              let scope = try? JSONDecoder().decode(SnippetAssetScope.self, from: data) else {
            return .allAssets
        }
        return scope
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

    private var db: SnippetStoreDB
    private var accountScope: AccountScope?
    private let network = NetworkService.shared
    private let orbitManager = OrbitManager()

    private enum MetaKey {
        static let remoteConfigID = "snippet_remote_config_id"
        static let vectorClock = "snippet_vector_clock"
        static let envelopeTime = "snippet_envelope_time"
    }

    private init() {
        self.db = SnippetStoreDB(fileURL: Self.databaseURL(scope: nil))
    }

    /// Selects one account-local snippets database. Signed-out views always see
    /// an empty in-memory list instead of a previous user's snippets.
    func activateAccount(username: String) {
        guard let scope = AccountScope(username: username) else {
            deactivateAccount()
            return
        }
        guard accountScope != scope else { return }
        orbitManager.clearConfigRootKeyV2()

        migrateLegacyDatabaseIfNeeded(to: scope)
        accountScope = scope
        db = SnippetStoreDB(fileURL: Self.databaseURL(scope: scope))
        let activeDatabase = db
        snippets = []
        lastSyncMessage = "Snippets 尚未同步"
        Task { [weak self] in
            await self?.reloadFromDB(database: activeDatabase, scope: scope)
        }
    }

    func deactivateAccount() {
        orbitManager.clearConfigRootKeyV2()
        accountScope = nil
        db = SnippetStoreDB(fileURL: Self.databaseURL(scope: nil))
        snippets = []
        lastSyncMessage = "Snippets 未同步"
    }

    func filteredSnippets(query: String, assetID: UUID? = nil) -> [Snippet] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return snippets.filter { snippet in
            let matchesAsset = assetID.map { snippet.assetScope.allows(assetID: $0) } ?? true
            guard matchesAsset else { return false }
            guard !q.isEmpty else { return true }
            return snippet.title.localizedCaseInsensitiveContains(q) ||
                snippet.command.localizedCaseInsensitiveContains(q) ||
                snippet.category.localizedCaseInsensitiveContains(q)
        }
    }

    func addSnippet(
        title: String,
        command: String,
        category: String,
        assetScope: SnippetAssetScope = .allAssets,
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
            category: trimmedCategory.isEmpty ? "未分类" : trimmedCategory,
            assetScope: assetScope
        )
        let scope = accountScope
        let activeDatabase = db
        await activeDatabase.upsert(snippet)
        await reloadFromDB(database: activeDatabase, scope: scope)
        await syncIfPossible(token: token, masterPassword: masterPassword, reason: "create")
    }

    func updateSnippet(
        _ snippet: Snippet,
        title: String,
        command: String,
        category: String,
        assetScope: SnippetAssetScope,
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
        updated.assetScope = assetScope
        updated.updatedAt = Date()

        let scope = accountScope
        let activeDatabase = db
        await activeDatabase.upsert(updated)
        await reloadFromDB(database: activeDatabase, scope: scope)
        await syncIfPossible(token: token, masterPassword: masterPassword, reason: "update")
    }

    func deleteSnippet(
        _ snippet: Snippet,
        token: String?,
        masterPassword: String?
    ) async {
        let scope = accountScope
        let activeDatabase = db
        await activeDatabase.remove(id: snippet.id)
        await reloadFromDB(database: activeDatabase, scope: scope)
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
            assetScope: .allAssets,
            token: token,
            masterPassword: masterPassword
        )
    }

    func pullFromCloud(token: String?, masterPassword: String?, accountID: String) async {
        guard let token, let masterPassword,
              let scope = AccountScope(username: accountID),
              scope == accountScope else { return }
        let activeDatabase = db
        do {
            let remoteItems = try await network.pullConfigs(token: token)
            guard scope == accountScope else { return }
            guard !remoteItems.isEmpty else {
                lastSyncMessage = "Snippets 拉取完成（云端为空）"
                return
            }

            let v2RootKey: Data?
            if remoteItems.contains(where: { item in
                Data(base64Encoded: item.encrypted_blob_base64).map(OrbitManager.isV2ConfigBlob) ?? false
            }) {
                try orbitManager.prepareConfigRootKeyV2(masterPassword: masterPassword, accountScope: scope)
                v2RootKey = try orbitManager.configRootKeyV2ForBackground(scope: scope)
            } else {
                v2RootKey = nil
            }
            defer { orbitManager.clearConfigRootKeyV2() }

            guard let latest = await latestSnippetEnvelopeBackground(
                remoteItems,
                masterPassword: masterPassword,
                v2RootKey: v2RootKey
            ) else {
                guard scope == accountScope else { return }
                lastSyncMessage = "Snippets 拉取完成（未发现 Snippet 数据）"
                return
            }

            let localEnvelopeTime = Int(await activeDatabase.readMeta(MetaKey.envelopeTime) ?? "0") ?? 0
            guard scope == accountScope else { return }
            if latest.envelope.updatedAtUnix >= localEnvelopeTime {
                await activeDatabase.replaceAll(latest.envelope.snippets)
                await activeDatabase.writeMeta(MetaKey.remoteConfigID, value: String(latest.configID))
                await activeDatabase.writeMeta(MetaKey.vectorClock, value: latest.vectorClock)
                await activeDatabase.writeMeta(MetaKey.envelopeTime, value: String(latest.envelope.updatedAtUnix))
                await reloadFromDB(database: activeDatabase, scope: scope)
                guard scope == accountScope else { return }
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
        masterPassword: String,
        v2RootKey: Data?
    ) async -> SnippetRemoteCandidate? {
        await Task.detached(priority: .utility) {
            var latest: SnippetRemoteCandidate?

            for item in remoteItems {
                guard let blobData = Data(base64Encoded: item.encrypted_blob_base64),
                      let plain = try? Self.decryptBlob(
                        password: masterPassword,
                        encrypted: blobData,
                        v2RootKey: v2RootKey
                      ),
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

    private nonisolated static func decryptBlob(
        password: String,
        encrypted: Data,
        v2RootKey: Data? = nil
    ) throws -> Data {
        if OrbitManager.isV2ConfigBlob(encrypted) {
            guard let v2RootKey, v2RootKey.count == 32 else {
                throw NetworkService.NetworkError.decodeFailed
            }
            let encryptedB64 = encrypted.base64EncodedString()
            guard let encryptedCString = encryptedB64.cString(using: .utf8) else {
                throw NetworkService.NetworkError.decodeFailed
            }
            let resultPtr = v2RootKey.withUnsafeBytes { keyBuffer in
                orbit_decrypt_config_v2(
                    keyBuffer.bindMemory(to: UInt8.self).baseAddress,
                    v2RootKey.count,
                    encryptedCString
                )
            }
            guard let resultPtr else { throw NetworkService.NetworkError.decodeFailed }
            defer { orbit_free_string(resultPtr) }
            let raw = String(cString: resultPtr)
            guard raw.hasPrefix("OK:"),
                  let decoded = Data(base64Encoded: String(raw.dropFirst(3))) else {
                throw NetworkService.NetworkError.decodeFailed
            }
            return decoded
        }
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
        guard let token, let masterPassword, let scope = accountScope else {
            lastSyncMessage = "Snippets 已本地保存，登录后自动同步"
            return
        }
        let activeDatabase = db

        // 首次同步前先尝试拉取一次远端 ID，避免在离线恢复后重复创建多条 Snippet 配置记录。
        if await activeDatabase.readMeta(MetaKey.remoteConfigID) == nil {
            await pullFromCloud(
                token: token,
                masterPassword: masterPassword,
                accountID: scope.canonicalUsername
            )
        }
        guard scope == accountScope else { return }

        guard let payload = try? await buildUploadPayload(
            masterPassword: masterPassword,
            database: activeDatabase
        ) else {
            guard scope == accountScope else { return }
            lastSyncMessage = "Snippets 同步失败: 无法构建加密负载"
            return
        }
        guard scope == accountScope else { return }

        do {
            let response = try await network.uploadConfig(token: token, payload: payload)
            guard scope == accountScope else { return }
            await activeDatabase.writeMeta(MetaKey.remoteConfigID, value: String(response.id))
            await activeDatabase.writeMeta(MetaKey.vectorClock, value: response.vector_clock)
            lastSyncMessage = "Snippets 已同步（\(reason)）"
        } catch {
            guard scope == accountScope else { return }
            if NetworkService.isRetriableNetworkError(error) {
                await SyncQueue.shared.enqueueUpload(
                    payload: payload,
                    accountID: scope.canonicalUsername,
                    reason: "snippets_\(reason)"
                )
                lastSyncMessage = "网络波动，Snippets 已加入重试队列"
                return
            }
            lastSyncMessage = "Snippets 同步失败: \(error.localizedDescription)"
        }
    }

    private func buildUploadPayload(
        masterPassword: String,
        database: SnippetStoreDB
    ) async throws -> UploadConfigRequest {
        let current = await database.loadAll()
        let envelopeTime = max(Int(Date().timeIntervalSince1970), Int(current.map(\.updatedAt).map(\.timeIntervalSince1970).max() ?? Date().timeIntervalSince1970))
        let envelope = SnippetSyncEnvelope(updatedAtUnix: envelopeTime, snippets: current)
        let plainData = try JSONEncoder().encode(envelope)
        guard let plainText = String(data: plainData, encoding: .utf8) else {
            throw NetworkService.NetworkError.decodeFailed
        }

        let encrypted: Data
        if let scope = accountScope, SyncService.isV2CipherWriteEnabled(scope: scope) {
            try orbitManager.prepareConfigRootKeyV2(masterPassword: masterPassword, accountScope: scope)
            encrypted = try orbitManager.encryptConfigV2(Data(plainText.utf8))
        } else {
            encrypted = try orbitManager.encrypt(password: masterPassword, data: plainText)
        }

        let previousID = await database.readMeta(MetaKey.remoteConfigID)
        let idValue = previousID.flatMap(UInt.init)
        let existingClock = await database.readMeta(MetaKey.vectorClock) ?? "{}"
        let nextClock = bumpedVectorClock(from: existingClock)

        await database.writeMeta(MetaKey.vectorClock, value: nextClock)
        await database.writeMeta(MetaKey.envelopeTime, value: String(envelopeTime))

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

    private func reloadFromDB(database: SnippetStoreDB, scope: AccountScope?) async {
        let loaded = await database.loadAll()
        guard accountScope == scope else { return }
        snippets = loaded
    }

    private static func databaseURL(scope: AccountScope?) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let fileName = scope?.databaseFileName("snippets", pathExtension: "sqlite") ?? "snippets-signed-out.sqlite"
        return base
            .appendingPathComponent("OrbitTerm", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private func migrateLegacyDatabaseIfNeeded(to scope: AccountScope) {
        let flagKey = "orbitterm.snippets.account-scope-migrated.v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let legacyURL = Self.databaseURL(scope: nil).deletingLastPathComponent().appendingPathComponent("snippets.sqlite")
        let scopedURL = Self.databaseURL(scope: scope)
        guard FileManager.default.fileExists(atPath: legacyURL.path),
              !FileManager.default.fileExists(atPath: scopedURL.path) else { return }

        do {
            try FileManager.default.createDirectory(at: scopedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: legacyURL, to: scopedURL)
            UserDefaults.standard.set(true, forKey: flagKey)
        } catch {
            // Keep the legacy database untouched. The account can still pull its
            // cloud snippets, and a later activation may retry this safe copy.
        }
    }
}
