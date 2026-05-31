import CryptoKit
import Foundation
import Network
import SQLite3
import os

enum ConflictField: String, CaseIterable {
    case name
    case group
    case host
    case port
    case username
    case authMethod
    case networkDeviceProfile
    case allowPasswordFallback
    case password
    case privateKeyContent
    case privateKeyPassphrase
}

enum ConflictChoice {
    case keepLocal
    case keepCloud
}

struct SyncConflictPrompt: Identifiable {
    let id = UUID()
    let serverID: String
    let conflictedFields: [ConflictField]
    let localSummary: String
    let cloudSummary: String
}

private struct ConflictDecision {
    let choice: ConflictChoice
}

private final class SyncShadowStore {
    private let key = "orbitterm.sync.shadow.v2"

    func read(id: String) -> PortableServerConfig? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: PortableServerConfig].self, from: data) else {
            return nil
        }
        return map[id]
    }

    func save(_ portable: PortableServerConfig) {
        var map = readAll()
        map[portable.id] = portable
        persist(map)
    }

    func readAll() -> [String: PortableServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: PortableServerConfig].self, from: data) else {
            return [:]
        }
        return map
    }

    func saveMany(_ portables: [PortableServerConfig]) {
        guard !portables.isEmpty else { return }
        var map = readAll()
        for portable in portables {
            map[portable.id] = portable
        }
        persist(map)
    }

    private func persist(_ map: [String: PortableServerConfig]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

private struct SyncPreparedItem {
    let server: ServerEntry
    let portable: PortableServerConfig
}

private struct SyncDecodedRemoteItem {
    let remoteID: UInt
    let server: ServerEntry
    let portable: PortableServerConfig
    let credentials: ServerCredentials
}

private struct SyncPullPreparation {
    let items: [SyncPreparedItem]
    let skipped: Int
    let tombstoneSkipped: Int
    let duplicateSkipped: Int
    let credentialWriteCount: Int
    let remoteConfigIDsToDelete: [UInt]
}

@MainActor
final class SyncService: ObservableObject {
    static let shared = SyncService()

    @Published var lastSyncMessage: String = "尚未同步"
    @Published var pendingConflictPrompt: SyncConflictPrompt?

    private let network: NetworkService
    private let orbitManager: OrbitManager
    private let vault: CredentialVault
    private let shadowStore = SyncShadowStore()
    private var conflictContinuation: CheckedContinuation<ConflictDecision, Never>?

    init(network: NetworkService = .shared, orbitManager: OrbitManager? = nil, vault: CredentialVault = .shared) {
        self.network = network
        self.orbitManager = orbitManager ?? OrbitManager()
        self.vault = vault
    }

    func chooseConflict(_ choice: ConflictChoice) {
        conflictContinuation?.resume(returning: ConflictDecision(choice: choice))
        conflictContinuation = nil
        pendingConflictPrompt = nil
    }

    func uploadEncryptedConfig(
        token: String,
        masterPassword: String,
        plaintextConfig: String,
        vectorClock: [String: Int],
        configID: UInt? = nil,
        allowQueueOnNetworkFailure: Bool = false
    ) async -> Bool {
        do {
            let decodedPortable = try decodePortable(from: plaintextConfig)
            let localPortable = try enrichPortableWithCredentialVault(decodedPortable)
            let normalizedPlain = try encodePortable(localPortable)
            let encrypted = try orbitManager.encrypt(password: masterPassword, data: normalizedPlain)
            let payload = UploadConfigRequest(
                id: configID,
                encrypted_blob_base64: encrypted.base64EncodedString(),
                vector_clock: Self.encodeVectorClock(vectorClock)
            )

            do {
                let response = try await network.uploadConfig(token: token, payload: payload)
                shadowStore.save(localPortable)
                lastSyncMessage = "同步成功，配置ID: \(response.id)"
                return true
            } catch {
                if isConflict(error) {
                    return await resolveConflictAndRetry(
                        token: token,
                        masterPassword: masterPassword,
                        localPortable: localPortable,
                        fallbackPayload: payload
                    )
                }
                if allowQueueOnNetworkFailure, NetworkService.isRetriableNetworkError(error) {
                    await SyncQueue.shared.enqueueUpload(payload: payload, reason: error.localizedDescription)
                    lastSyncMessage = "网络波动，已加入后台同步队列"
                    return true
                }
                if let net = error as? NetworkService.NetworkError,
                   case .unauthorized = net {
                    lastSyncMessage = "登录已过期，请重新登录后自动同步"
                    return false
                }
                throw error
            }
        } catch {
            lastSyncMessage = "同步失败: \(error.localizedDescription)"
            return false
        }
    }

    func pullAndApplyConfigs(
        token: String,
        masterPassword: String,
        store: ServerStore,
        incremental: Bool = false,
        silentStart: Bool = false
    ) async -> Bool {
        do {
            if !silentStart {
                lastSyncMessage = "正在后台同步..."
            }
            let remoteItems = try await network.pullConfigs(token: token)
            if remoteItems.isEmpty {
                lastSyncMessage = "拉取完成: 云端暂无配置"
                return true
            }

            let shadowSnapshot = shadowStore.readAll()
            let tombstoneSnapshot = DeletedServerRegistry.shared.snapshot()
            let preparation = try await preparePullResultBackground(
                remoteItems,
                masterPassword: masterPassword,
                shadowSnapshot: shadowSnapshot,
                tombstoneSnapshot: tombstoneSnapshot
            )

            let servers = preparation.items.map(\.server)
            let portables = preparation.items.map(\.portable)
            let appliedServerCount: Int
            if incremental {
                appliedServerCount = await store.applySyncedServersIncrementally(servers, batchSize: 6)
            } else {
                let metadataChanged = !store.containsSameServers(servers)
                if metadataChanged {
                    store.applySyncedServers(servers)
                }
                appliedServerCount = metadataChanged ? servers.count : 0
            }
            shadowStore.saveMany(portables)

            deleteRemoteConfigsInBackground(ids: preparation.remoteConfigIDsToDelete)

            let changedCount = preparation.credentialWriteCount + appliedServerCount
            if changedCount == 0 {
                lastSyncMessage = "后台同步完成: 云端无变化"
            } else {
                let ignored = preparation.skipped + preparation.tombstoneSkipped + preparation.duplicateSkipped
                lastSyncMessage = "后台同步完成: 更新 \(appliedServerCount) 条，凭据变更 \(preparation.credentialWriteCount) 条，忽略 \(ignored) 条"
            }
            return !servers.isEmpty || preparation.skipped == 0
        } catch {
            if let net = error as? NetworkService.NetworkError,
               case .unauthorized = net {
                lastSyncMessage = "登录已过期，请重新登录"
                return false
            }
            lastSyncMessage = "拉取失败: \(error.localizedDescription)"
            return false
        }
    }

    private func preparePullResultBackground(
        _ remoteItems: [UploadConfigData],
        masterPassword: String,
        shadowSnapshot: [String: PortableServerConfig],
        tombstoneSnapshot: [String: TimeInterval]
    ) async throws -> SyncPullPreparation {
        let vault = self.vault
        return try await Task.detached(priority: .utility) {
            var bestByServerID: [String: SyncDecodedRemoteItem] = [:]
            var skipped = 0
            var tombstoneSkipped = 0
            var duplicateSkipped = 0
            var credentialWriteCount = 0
            var remoteConfigIDsToDelete: Set<UInt> = []

            for item in remoteItems {
                do {
                    let portable = try Self.decryptPortableStatic(item, masterPassword: masterPassword)
                    if tombstoneSnapshot[portable.id] != nil {
                        tombstoneSkipped += 1
                        remoteConfigIDsToDelete.insert(item.id)
                        continue
                    }
                    guard let serverID = UUID(uuidString: portable.id) else {
                        skipped += 1
                        continue
                    }
                    let credentialID = UUID(uuidString: portable.credentialID) ?? serverID
                    let credentials = ServerCredentials(
                        password: portable.password,
                        privateKeyContent: portable.privateKeyContent,
                        privateKeyPassphrase: portable.privateKeyPassphrase
                    )

                    let server = ServerEntry(
                        id: serverID,
                        name: portable.name,
                        group: portable.group,
                        host: portable.host,
                        port: portable.port,
                        username: portable.username,
                        authMethod: portable.authMethod == ServerAuthMethod.key.rawValue ? .key : .password,
                        transport: portable.transport == ServerTransportProtocol.telnet.rawValue ? .telnet : .ssh,
                        networkDeviceProfile: NetworkDeviceProfile(rawValue: portable.networkDeviceProfile) ?? .auto,
                        allowPasswordFallback: portable.allowPasswordFallback,
                        credentialID: credentialID,
                        createdAt: Date(timeIntervalSince1970: TimeInterval(portable.savedAtUnix))
                    )
                    let decoded = SyncDecodedRemoteItem(
                        remoteID: item.id,
                        server: server,
                        portable: portable,
                        credentials: credentials
                    )
                    if let existing = bestByServerID[portable.id] {
                        if Self.shouldPrefer(decoded.portable, remoteID: decoded.remoteID, over: existing.portable, existingRemoteID: existing.remoteID) {
                            remoteConfigIDsToDelete.insert(existing.remoteID)
                            bestByServerID[portable.id] = decoded
                        } else {
                            remoteConfigIDsToDelete.insert(item.id)
                        }
                        duplicateSkipped += 1
                    } else {
                        bestByServerID[portable.id] = decoded
                    }
                } catch {
                    skipped += 1
                }
            }

            let chosen = bestByServerID.values.sorted {
                $0.server.name.localizedCaseInsensitiveCompare($1.server.name) == .orderedAscending
            }
            var prepared: [SyncPreparedItem] = []
            for item in chosen {
                let shouldCheckCredentials = shadowSnapshot[item.portable.id] != item.portable
                let existingCredentials = try? vault.read(for: item.server.credentialID)
                if shouldCheckCredentials || existingCredentials == nil || existingCredentials != item.credentials {
                    try vault.save(item.credentials, for: item.server.credentialID)
                    credentialWriteCount += 1
                }
                prepared.append(SyncPreparedItem(server: item.server, portable: item.portable))
            }

            return SyncPullPreparation(
                items: prepared,
                skipped: skipped,
                tombstoneSkipped: tombstoneSkipped,
                duplicateSkipped: duplicateSkipped,
                credentialWriteCount: credentialWriteCount,
                remoteConfigIDsToDelete: Array(remoteConfigIDsToDelete)
            )
        }.value
    }

    func deleteRemoteConfigs(for servers: [ServerEntry], token: String?, masterPassword: String?) async {
        guard !servers.isEmpty else { return }
        guard token != nil, let masterPassword else {
            lastSyncMessage = "已本地删除，登录并解锁后将忽略云端旧副本"
            return
        }

        do {
            let ids = Set(servers.map { $0.id.uuidString })
            let remoteItems = try await network.pullConfigs(token: token ?? "")
            var remoteIDs: [UInt] = []
            for item in remoteItems {
                guard let portable = try? await decryptPortableBackground(item, masterPassword: masterPassword),
                      ids.contains(portable.id) else { continue }
                remoteIDs.append(item.id)
            }
            for id in remoteIDs {
                try? await network.deleteConfig(id: id)
            }
            if !remoteIDs.isEmpty {
                lastSyncMessage = "已同步删除 \(remoteIDs.count) 条云端资产"
            }
        } catch {
            lastSyncMessage = "已本地删除，云端删除稍后重试: \(error.localizedDescription)"
        }
    }

    private func deleteRemoteConfigsInBackground(ids: [UInt]) {
        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else { return }
        Task(priority: .background) { [network] in
            for id in uniqueIDs {
                try? await network.deleteConfig(id: id)
            }
        }
    }

    nonisolated private static func shouldPrefer(
        _ candidate: PortableServerConfig,
        remoteID: UInt,
        over existing: PortableServerConfig,
        existingRemoteID: UInt
    ) -> Bool {
        if candidate.savedAtUnix != existing.savedAtUnix {
            return candidate.savedAtUnix > existing.savedAtUnix
        }
        return remoteID > existingRemoteID
    }

    private func resolveConflictAndRetry(
        token: String,
        masterPassword: String,
        localPortable: PortableServerConfig,
        fallbackPayload: UploadConfigRequest
    ) async -> Bool {
        do {
            let remoteItems = try await network.pullConfigs(token: token)
            let decoded = remoteItems.compactMap { item -> (UploadConfigData, PortableServerConfig)? in
                guard let portable = try? decryptPortable(item, masterPassword: masterPassword) else { return nil }
                return (item, portable)
            }

            guard let target = decoded.first(where: { $0.1.id == localPortable.id }) else {
                await SyncQueue.shared.enqueueUpload(payload: fallbackPayload, reason: "conflict_pull_missing")
                lastSyncMessage = "冲突处理失败：未找到云端同名配置"
                return false
            }

            let remoteMeta = target.0
            let remotePortable = target.1
            let basePortable = shadowStore.read(id: localPortable.id)

            if let basePortable {
                let localChanged = changedFields(from: basePortable, to: localPortable)
                let remoteChanged = changedFields(from: basePortable, to: remotePortable)
                let conflictFields = localChanged.intersection(remoteChanged)

                if conflictFields.isEmpty {
                    let merged = mergedPortable(base: remotePortable, local: localPortable, localChanged: localChanged)
                    let mergedPayload = try await buildPayload(
                        portable: merged,
                        masterPassword: masterPassword,
                        remoteMeta: remoteMeta
                    )
                    _ = try await network.uploadConfig(token: token, payload: mergedPayload)
                    shadowStore.save(merged)
                    lastSyncMessage = "冲突已静默合并并同步"
                    return true
                }

                let choice = await askUserConflictDecision(
                    local: localPortable,
                    remote: remotePortable,
                    conflictedFields: Array(conflictFields).sorted { $0.rawValue < $1.rawValue }
                )

                switch choice.choice {
                case .keepLocal:
                    let retryPayload = try await buildPayload(
                        portable: localPortable,
                        masterPassword: masterPassword,
                        remoteMeta: remoteMeta
                    )
                    _ = try await network.uploadConfig(token: token, payload: retryPayload)
                    shadowStore.save(localPortable)
                    lastSyncMessage = "已保留本地修改并覆盖云端"
                    return true
                case .keepCloud:
                    shadowStore.save(remotePortable)
                    lastSyncMessage = "已保留云端版本，本地修改未覆盖"
                    return true
                }
            } else {
                let choice = await askUserConflictDecision(
                    local: localPortable,
                    remote: remotePortable,
                    conflictedFields: ConflictField.allCases
                )
                switch choice.choice {
                case .keepLocal:
                    let retryPayload = try await buildPayload(
                        portable: localPortable,
                        masterPassword: masterPassword,
                        remoteMeta: remoteMeta
                    )
                    _ = try await network.uploadConfig(token: token, payload: retryPayload)
                    shadowStore.save(localPortable)
                    lastSyncMessage = "已保留本地修改并覆盖云端"
                    return true
                case .keepCloud:
                    shadowStore.save(remotePortable)
                    lastSyncMessage = "已保留云端版本，本地修改未覆盖"
                    return true
                }
            }
        } catch {
            lastSyncMessage = "冲突处理失败: \(error.localizedDescription)"
            return false
        }
    }

    private func askUserConflictDecision(
        local: PortableServerConfig,
        remote: PortableServerConfig,
        conflictedFields: [ConflictField]
    ) async -> ConflictDecision {
        let localSummary = "名称: \(local.name)\n分组: \(local.group)\n主机: \(local.host):\(local.port)\n用户: \(local.username)"
        let cloudSummary = "名称: \(remote.name)\n分组: \(remote.group)\n主机: \(remote.host):\(remote.port)\n用户: \(remote.username)"
        pendingConflictPrompt = SyncConflictPrompt(
            serverID: local.id,
            conflictedFields: conflictedFields,
            localSummary: localSummary,
            cloudSummary: cloudSummary
        )
        return await withCheckedContinuation { continuation in
            conflictContinuation = continuation
        }
    }

    private func mergedPortable(
        base remote: PortableServerConfig,
        local: PortableServerConfig,
        localChanged: Set<ConflictField>
    ) -> PortableServerConfig {
        PortableServerConfig(
            id: remote.id,
            credentialID: local.credentialID,
            name: localChanged.contains(.name) ? local.name : remote.name,
            group: localChanged.contains(.group) ? local.group : remote.group,
            host: localChanged.contains(.host) ? local.host : remote.host,
            port: localChanged.contains(.port) ? local.port : remote.port,
            username: localChanged.contains(.username) ? local.username : remote.username,
            authMethod: localChanged.contains(.authMethod) ? local.authMethod : remote.authMethod,
            transport: localChanged.contains(.host) || localChanged.contains(.port) || localChanged.contains(.username) ? local.transport : remote.transport,
            networkDeviceProfile: localChanged.contains(.networkDeviceProfile) ? local.networkDeviceProfile : remote.networkDeviceProfile,
            allowPasswordFallback: localChanged.contains(.allowPasswordFallback) ? local.allowPasswordFallback : remote.allowPasswordFallback,
            password: localChanged.contains(.password) ? local.password : remote.password,
            privateKeyContent: localChanged.contains(.privateKeyContent) ? local.privateKeyContent : remote.privateKeyContent,
            privateKeyPassphrase: localChanged.contains(.privateKeyPassphrase) ? local.privateKeyPassphrase : remote.privateKeyPassphrase,
            keyReference: local.keyReference,
            savedAtUnix: Int(Date().timeIntervalSince1970)
        )
    }

    private func changedFields(from base: PortableServerConfig, to newer: PortableServerConfig) -> Set<ConflictField> {
        var changed = Set<ConflictField>()
        if base.name != newer.name { changed.insert(.name) }
        if base.group != newer.group { changed.insert(.group) }
        if base.host != newer.host { changed.insert(.host) }
        if base.port != newer.port { changed.insert(.port) }
        if base.username != newer.username { changed.insert(.username) }
        if base.authMethod != newer.authMethod { changed.insert(.authMethod) }
        if base.networkDeviceProfile != newer.networkDeviceProfile { changed.insert(.networkDeviceProfile) }
        if base.allowPasswordFallback != newer.allowPasswordFallback { changed.insert(.allowPasswordFallback) }
        if base.password != newer.password { changed.insert(.password) }
        if base.privateKeyContent != newer.privateKeyContent { changed.insert(.privateKeyContent) }
        if base.privateKeyPassphrase != newer.privateKeyPassphrase { changed.insert(.privateKeyPassphrase) }
        return changed
    }

    private func buildPayload(
        portable: PortableServerConfig,
        masterPassword: String,
        remoteMeta: UploadConfigData
    ) async throws -> UploadConfigRequest {
        let plain = try encodePortable(portable)
        let encrypted = try orbitManager.encrypt(password: masterPassword, data: plain)
        let mergedClock = Self.bumpClock(remoteMeta.vector_clock, actor: "client")
        return UploadConfigRequest(
            id: remoteMeta.id,
            encrypted_blob_base64: encrypted.base64EncodedString(),
            vector_clock: mergedClock
        )
    }

    private static func bumpClock(_ raw: String, actor: String) -> String {
        var map = (try? JSONDecoder().decode([String: Int].self, from: Data(raw.utf8))) ?? [:]
        map[actor] = (map[actor] ?? 0) + 1
        return encodeVectorClock(map)
    }

    private static func encodeVectorClock(_ map: [String: Int]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func encodePortable(_ portable: PortableServerConfig) throws -> String {
        let data = try JSONEncoder().encode(portable)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        return text
    }

    private func decodePortable(from plaintext: String) throws -> PortableServerConfig {
        guard let data = plaintext.data(using: .utf8) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        return try JSONDecoder().decode(PortableServerConfig.self, from: data)
    }

    private func enrichPortableWithCredentialVault(_ portable: PortableServerConfig) throws -> PortableServerConfig {
        guard let credentialUUID = UUID(uuidString: portable.credentialID),
              let credentials = try vault.read(for: credentialUUID) else {
            return portable
        }
        return PortableServerConfig(
            id: portable.id,
            credentialID: portable.credentialID,
            name: portable.name,
            group: portable.group,
            host: portable.host,
            port: portable.port,
            username: portable.username,
            authMethod: portable.authMethod,
            transport: portable.transport,
            networkDeviceProfile: portable.networkDeviceProfile,
            allowPasswordFallback: portable.allowPasswordFallback,
            password: credentials.password,
            privateKeyContent: credentials.privateKeyContent,
            privateKeyPassphrase: credentials.privateKeyPassphrase,
            keyReference: portable.keyReference,
            savedAtUnix: portable.savedAtUnix
        )
    }

    private func decryptPortable(_ item: UploadConfigData, masterPassword: String) throws -> PortableServerConfig {
        guard let encrypted = Data(base64Encoded: item.encrypted_blob_base64) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        let plainData = try orbitManager.decrypt(password: masterPassword, encrypted: encrypted)
        guard let plainText = String(data: plainData, encoding: .utf8),
              let portableData = plainText.data(using: .utf8) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        return try JSONDecoder().decode(PortableServerConfig.self, from: portableData)
    }

    nonisolated private static func decryptPortableStatic(_ item: UploadConfigData, masterPassword: String) throws -> PortableServerConfig {
        guard let encrypted = Data(base64Encoded: item.encrypted_blob_base64) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        let plainData = try decryptBlob(password: masterPassword, encrypted: encrypted)
        guard let plainText = String(data: plainData, encoding: .utf8),
              let portableData = plainText.data(using: .utf8) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        return try JSONDecoder().decode(PortableServerConfig.self, from: portableData)
    }

    private func decryptPortableBackground(_ item: UploadConfigData, masterPassword: String) async throws -> PortableServerConfig {
        try await Task.detached(priority: .utility) {
            try Self.decryptPortableStatic(item, masterPassword: masterPassword)
        }.value
    }

    nonisolated private static func decryptBlob(password: String, encrypted: Data) throws -> Data {
        guard let passwordCString = password.cString(using: .utf8) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        let encryptedB64 = encrypted.base64EncodedString()
        guard let encryptedCString = encryptedB64.cString(using: .utf8) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        guard let resultPtr = orbit_decrypt_config(passwordCString, encryptedCString) else {
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

    private func isConflict(_ error: Error) -> Bool {
        if let net = error as? NetworkService.NetworkError {
            switch net {
            case let .server(message):
                return message.contains("版本冲突") || message.lowercased().contains("conflict")
            case let .unexpectedStatus(code):
                return code == 409
            default:
                return false
            }
        }
        let msg = error.localizedDescription.lowercased()
        return msg.contains("409") || msg.contains("冲突") || msg.contains("conflict")
    }
}

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
