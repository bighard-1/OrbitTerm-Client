import Foundation

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

struct RecentlyDeletedAsset: Identifiable {
    let remote: UploadConfigData
    let portable: PortableServerConfig?
    let decryptionError: String?

    var id: String {
        remote.asset_id ?? "remote-\(remote.id)"
    }

    var assetID: UUID? {
        remote.asset_id.flatMap(UUID.init(uuidString:))
    }

    var displayName: String {
        portable?.name ?? "无法解密的资产"
    }

    var endpoint: String {
        guard let portable else { return "配置 ID: \(remote.id)" }
        return "\(portable.username)@\(portable.host):\(portable.port)"
    }

    var purgeDate: Date? {
        Self.parseISO8601(remote.purge_after)
    }

    var remainingDays: Int? {
        guard let purgeDate else { return nil }
        return max(0, Int(ceil(purgeDate.timeIntervalSinceNow / 86_400)))
    }

    private static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

enum RecentlyDeletedMutationOutcome {
    case completed
    case queued
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
    let remote: UploadConfigData
}

private struct SyncDecodedRemoteItem {
    let remoteID: UInt
    let server: ServerEntry
    let portable: PortableServerConfig
    let credentials: ServerCredentials
    let remote: UploadConfigData
}

private struct SyncPullPreparation {
    let items: [SyncPreparedItem]
    let tombstonedRemotes: [(assetID: UUID, remote: UploadConfigData)]
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
        accountID: String,
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
            let identityFingerprint = try await SyncIdentityService.fingerprint(
                portable: localPortable,
                accountID: accountID,
                masterPassword: masterPassword
            )
            let assetID = UUID(uuidString: localPortable.id)
            let encodedClock = assetID.map {
                SyncMetadataStore.shared.nextVectorClock(assetID: $0, accountID: accountID)
            } ?? Self.encodeVectorClock(vectorClock)
            let payload = UploadConfigRequest(
                id: configID,
                encrypted_blob_base64: encrypted.base64EncodedString(),
                vector_clock: encodedClock,
                asset_id: localPortable.id,
                identity_fingerprint: identityFingerprint
            )

            do {
                let response = try await network.uploadConfig(token: token, payload: payload)
                shadowStore.save(localPortable)
                if let assetID {
                    SyncMetadataStore.shared.saveAsset(response, fallbackAssetID: assetID, accountID: accountID)
                }
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
        accountID: String,
        incremental: Bool = false,
        silentStart: Bool = false
    ) async -> Bool {
        do {
            return try await pullIncrementalAndApplyConfigs(
                token: token,
                masterPassword: masterPassword,
                store: store,
                accountID: accountID,
                incremental: incremental,
                silentStart: silentStart
            )
        } catch {
            if isMissingOrUnsupportedTombstoneAPI(error) {
                return await pullLegacyAndApplyConfigs(
                    token: token,
                    masterPassword: masterPassword,
                    store: store,
                    incremental: incremental,
                    silentStart: silentStart
                )
            }
            if isUnauthorized(error) {
                lastSyncMessage = "登录已过期，请重新登录"
            } else {
                lastSyncMessage = "拉取失败: \(error.localizedDescription)"
            }
            return false
        }
    }

    private func pullLegacyAndApplyConfigs(
        token: String,
        masterPassword: String,
        store: ServerStore,
        incremental: Bool,
        silentStart: Bool
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

    private func pullIncrementalAndApplyConfigs(
        token: String,
        masterPassword: String,
        store: ServerStore,
        accountID: String,
        incremental: Bool,
        silentStart: Bool
    ) async throws -> Bool {
        if !silentStart {
            lastSyncMessage = "正在后台增量同步..."
        }

        let metadata = SyncMetadataStore.shared
        var cursor = metadata.cursor(accountID: accountID)
        var resetAttempted = false
        var appliedCount = 0
        var deletedCount = 0
        var credentialCount = 0

        while true {
            let page = try await network.pullConfigChanges(cursor: cursor, limit: 100)
            if page.reset_required {
                guard !resetAttempted else {
                    throw NetworkService.NetworkError.server("同步游标连续失效，请稍后重试")
                }
                metadata.resetCursor(accountID: accountID)
                cursor = 0
                resetAttempted = true
                continue
            }

            let remoteDeletes = page.items.filter { ($0.state ?? "active") != "active" }
            for item in remoteDeletes {
                guard let rawID = item.asset_id, let assetID = UUID(uuidString: rawID) else { continue }
                store.applyRemoteDeletion(assetID)
                metadata.saveAsset(item, fallbackAssetID: assetID, accountID: accountID)
                deletedCount += 1
            }

            let remoteActive = page.items.filter { ($0.state ?? "active") == "active" }
            let preparation = try await preparePullResultBackground(
                remoteActive,
                masterPassword: masterPassword,
                shadowSnapshot: shadowStore.readAll(),
                tombstoneSnapshot: DeletedServerRegistry.shared.snapshot()
            )

            for tombstone in preparation.tombstonedRemotes {
                await publishMigratedLocalTombstone(
                    assetID: tombstone.assetID,
                    remote: tombstone.remote,
                    token: token,
                    accountID: accountID
                )
            }

            let servers = preparation.items.map(\.server)
            let changed: Int
            if incremental {
                changed = await store.applySyncedServersIncrementally(servers, batchSize: 6)
            } else {
                let metadataChanged = !store.containsSameServers(servers)
                if metadataChanged {
                    store.applySyncedServers(servers)
                }
                changed = metadataChanged ? servers.count : 0
            }
            appliedCount += changed
            credentialCount += preparation.credentialWriteCount
            shadowStore.saveMany(preparation.items.map(\.portable))
            for prepared in preparation.items {
                metadata.saveAsset(prepared.remote, fallbackAssetID: prepared.server.id, accountID: accountID)
            }

            metadata.saveCursor(page.next_cursor, accountID: accountID)
            cursor = page.next_cursor
            try? await network.acknowledgeConfigSync(SyncAcknowledgementRequest(
                device_id: metadata.deviceID.uuidString,
                revision: cursor,
                platform: SyncClientInfo.platform,
                client_version: SyncClientInfo.version
            ))

            guard page.has_more else { break }
            await Task.yield()
        }

        if appliedCount + deletedCount + credentialCount == 0 {
            lastSyncMessage = "后台同步完成: 云端无变化"
        } else {
            lastSyncMessage = "后台同步完成: 更新 \(appliedCount) 条，删除 \(deletedCount) 条，凭据变更 \(credentialCount) 条"
        }
        return true
    }

    private func publishMigratedLocalTombstone(
        assetID: UUID,
        remote: UploadConfigData,
        token: String,
        accountID: String
    ) async {
        let metadata = SyncMetadataStore.shared
        metadata.saveAsset(remote, fallbackAssetID: assetID, accountID: accountID)

        if remote.asset_id?.isEmpty != false {
            let bindClock = metadata.nextVectorClock(assetID: assetID, accountID: accountID)
            let bindPayload = UploadConfigRequest(
                id: remote.id,
                encrypted_blob_base64: remote.encrypted_blob_base64,
                vector_clock: bindClock,
                asset_id: assetID.uuidString
            )
            do {
                let boundRemote = try await network.uploadConfig(token: token, payload: bindPayload)
                metadata.saveAsset(boundRemote, fallbackAssetID: assetID, accountID: accountID)
            } catch {
                await SyncQueue.shared.enqueueUpload(payload: bindPayload, reason: error.localizedDescription)
                let deleteClock = metadata.incrementVectorClock(bindClock)
                let deleteRequest = AssetMutationRequest(
                    deviceID: metadata.deviceID,
                    vectorClock: deleteClock
                )
                await SyncQueue.shared.enqueueDelete(assetID: assetID, request: deleteRequest, reason: "waiting_for_asset_id_binding")
                return
            }
        }

        let deleteRequest = AssetMutationRequest(
            deviceID: metadata.deviceID,
            vectorClock: metadata.nextVectorClock(assetID: assetID, accountID: accountID)
        )
        do {
            let deleted = try await network.moveAssetToTrash(assetID: assetID, request: deleteRequest)
            metadata.saveAsset(deleted, fallbackAssetID: assetID, accountID: accountID)
            DeletedServerRegistry.shared.clear(assetID)
        } catch {
            await SyncQueue.shared.enqueueDelete(assetID: assetID, request: deleteRequest, reason: error.localizedDescription)
        }
    }

    func loadRecentlyDeleted(
        masterPassword: String,
        accountID: String
    ) async throws -> [RecentlyDeletedAsset] {
        let trash = try await network.pullTrash(limit: 500)
        let metadata = SyncMetadataStore.shared
        var results: [RecentlyDeletedAsset] = []

        for remote in trash.items {
            if let rawAssetID = remote.asset_id, let assetID = UUID(uuidString: rawAssetID) {
                metadata.saveAsset(remote, fallbackAssetID: assetID, accountID: accountID)
            }
            do {
                let portable = try await decryptPortableBackground(remote, masterPassword: masterPassword)
                results.append(RecentlyDeletedAsset(remote: remote, portable: portable, decryptionError: nil))
            } catch {
                // 密文无法解密时仍允许用户查看并永久清理墓碑，但禁止不完整恢复。
                results.append(RecentlyDeletedAsset(
                    remote: remote,
                    portable: nil,
                    decryptionError: "主密码无法解密此资产"
                ))
            }
        }

        return results.sorted {
            ($0.remote.deleted_at ?? "") > ($1.remote.deleted_at ?? "")
        }
    }

    func restoreRecentlyDeleted(
        _ item: RecentlyDeletedAsset,
        store: ServerStore,
        accountID: String
    ) async throws -> RecentlyDeletedMutationOutcome {
        guard let assetID = item.assetID, let portable = item.portable else {
            throw NetworkService.NetworkError.server("资产密文无法解密，不能恢复")
        }

        let metadata = SyncMetadataStore.shared
        metadata.saveAsset(item.remote, fallbackAssetID: assetID, accountID: accountID)
        let request = AssetMutationRequest(
            deviceID: metadata.deviceID,
            vectorClock: metadata.nextVectorClock(assetID: assetID, accountID: accountID)
        )

        do {
            let restored = try await network.restoreAsset(assetID: assetID, request: request)
            let server = try Self.makeServer(from: portable)
            let credentials = Self.makeCredentials(from: portable)

            // 先确认 Keychain 写入成功，再把普通资产元数据暴露给 UI。
            try vault.save(credentials, for: server.credentialID)
            store.addOrUpdate(server)
            shadowStore.save(portable)
            metadata.saveAsset(restored, fallbackAssetID: assetID, accountID: accountID)
            DeletedServerRegistry.shared.clear(assetID)
            lastSyncMessage = "已恢复 \(server.name)"
            return .completed
        } catch {
            if NetworkService.isRetriableNetworkError(error) || isUnauthorized(error) {
                await SyncQueue.shared.enqueueRestore(assetID: assetID, request: request, reason: error.localizedDescription)
                lastSyncMessage = "恢复任务已加入后台队列，联网后自动完成"
                return .queued
            }
            throw error
        }
    }

    func purgeRecentlyDeleted(
        _ item: RecentlyDeletedAsset,
        accountID: String
    ) async throws -> RecentlyDeletedMutationOutcome {
        guard let assetID = item.assetID else {
            throw NetworkService.NetworkError.server("资产标识无效，无法永久删除")
        }

        let metadata = SyncMetadataStore.shared
        metadata.saveAsset(item.remote, fallbackAssetID: assetID, accountID: accountID)
        let request = AssetMutationRequest(
            deviceID: metadata.deviceID,
            vectorClock: metadata.nextVectorClock(assetID: assetID, accountID: accountID),
            confirmation: "CONFIRM"
        )

        do {
            let purged = try await network.purgeAsset(assetID: assetID, request: request)
            metadata.saveAsset(purged, fallbackAssetID: assetID, accountID: accountID)
            DeletedServerRegistry.shared.clear(assetID)
            lastSyncMessage = "资产已永久删除"
            return .completed
        } catch {
            if NetworkService.isRetriableNetworkError(error) || isUnauthorized(error) {
                await SyncQueue.shared.enqueuePurge(assetID: assetID, request: request, reason: error.localizedDescription)
                lastSyncMessage = "永久删除任务已加入后台队列"
                return .queued
            }
            throw error
        }
    }

    nonisolated private static func makeServer(from portable: PortableServerConfig) throws -> ServerEntry {
        guard let serverID = UUID(uuidString: portable.id) else {
            throw NetworkService.NetworkError.server("资产 UUID 无效")
        }
        return ServerEntry(
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
            credentialID: UUID(uuidString: portable.credentialID) ?? serverID,
            createdAt: Date(timeIntervalSince1970: TimeInterval(portable.savedAtUnix))
        )
    }

    nonisolated private static func makeCredentials(from portable: PortableServerConfig) -> ServerCredentials {
        ServerCredentials(
            password: portable.password,
            privateKeyContent: portable.privateKeyContent,
            privateKeyPassphrase: portable.privateKeyPassphrase
        )
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
            var tombstonedRemotes: [(assetID: UUID, remote: UploadConfigData)] = []

            for item in remoteItems {
                do {
                    let portable = try Self.decryptPortableStatic(item, masterPassword: masterPassword)
                    if tombstoneSnapshot[portable.id] != nil {
                        tombstoneSkipped += 1
                        remoteConfigIDsToDelete.insert(item.id)
                        if let assetID = UUID(uuidString: portable.id) {
                            tombstonedRemotes.append((assetID: assetID, remote: item))
                        }
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
                        credentials: credentials,
                        remote: item
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
                prepared.append(SyncPreparedItem(server: item.server, portable: item.portable, remote: item.remote))
            }

            return SyncPullPreparation(
                items: prepared,
                tombstonedRemotes: tombstonedRemotes,
                skipped: skipped,
                tombstoneSkipped: tombstoneSkipped,
                duplicateSkipped: duplicateSkipped,
                credentialWriteCount: credentialWriteCount,
                remoteConfigIDsToDelete: Array(remoteConfigIDsToDelete)
            )
        }.value
    }

    func deleteRemoteConfigs(
        for servers: [ServerEntry],
        token: String?,
        masterPassword: String?,
        accountID: String
    ) async {
        guard !servers.isEmpty else { return }
        let metadata = SyncMetadataStore.shared
        var syncedCount = 0
        var queuedCount = 0

        for server in servers {
            let request = AssetMutationRequest(
                deviceID: metadata.deviceID,
                vectorClock: metadata.nextVectorClock(assetID: server.id, accountID: accountID)
            )
            guard token != nil else {
                await SyncQueue.shared.enqueueDelete(assetID: server.id, request: request, reason: "waiting_for_login")
                queuedCount += 1
                continue
            }

            do {
                let response = try await network.moveAssetToTrash(assetID: server.id, request: request)
                metadata.saveAsset(response, fallbackAssetID: server.id, accountID: accountID)
                DeletedServerRegistry.shared.clear(server.id)
                syncedCount += 1
            } catch {
                if NetworkService.isRetriableNetworkError(error) || isUnauthorized(error) {
                    await SyncQueue.shared.enqueueDelete(assetID: server.id, request: request, reason: error.localizedDescription)
                    queuedCount += 1
                    continue
                }
                if isMissingOrUnsupportedTombstoneAPI(error),
                   let masterPassword,
                   await deleteLegacyRemoteConfig(server, token: token, masterPassword: masterPassword) {
                    DeletedServerRegistry.shared.clear(server.id)
                    syncedCount += 1
                    continue
                }
                await SyncQueue.shared.enqueueDelete(assetID: server.id, request: request, reason: error.localizedDescription)
                queuedCount += 1
            }
        }

        if queuedCount > 0 {
            lastSyncMessage = "已本地删除，\(queuedCount) 条删除任务将在后台重试"
        } else {
            lastSyncMessage = "已同步删除 \(syncedCount) 条云端资产，可在最近删除中恢复"
        }
    }

    private func deleteLegacyRemoteConfig(_ server: ServerEntry, token: String?, masterPassword: String) async -> Bool {
        guard let token else { return false }
        do {
            let remoteItems = try await network.pullConfigs(token: token)
            for item in remoteItems {
                guard let portable = try? await decryptPortableBackground(item, masterPassword: masterPassword),
                      portable.id == server.id.uuidString else { continue }
                try await network.deleteConfig(id: item.id)
                return true
            }
            return false
        } catch {
            return false
        }
    }

    private func isUnauthorized(_ error: Error) -> Bool {
        guard let networkError = error as? NetworkService.NetworkError else { return false }
        if case .unauthorized = networkError { return true }
        return false
    }

    private func isMissingOrUnsupportedTombstoneAPI(_ error: Error) -> Bool {
        guard let networkError = error as? NetworkService.NetworkError else { return false }
        switch networkError {
        case .unexpectedStatus(404):
            return true
        case let .server(message):
            return message.contains("不存在") || message.contains("not found")
        default:
            return false
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
                        remoteMeta: remoteMeta,
                        identityFingerprint: fallbackPayload.identity_fingerprint
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
                        remoteMeta: remoteMeta,
                        identityFingerprint: fallbackPayload.identity_fingerprint
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
                        remoteMeta: remoteMeta,
                        identityFingerprint: fallbackPayload.identity_fingerprint
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
        remoteMeta: UploadConfigData,
        identityFingerprint: String?
    ) async throws -> UploadConfigRequest {
        let plain = try encodePortable(portable)
        let encrypted = try orbitManager.encrypt(password: masterPassword, data: plain)
        let mergedClock = Self.bumpClock(remoteMeta.vector_clock, actor: "client")
        return UploadConfigRequest(
            id: remoteMeta.id,
            encrypted_blob_base64: encrypted.base64EncodedString(),
            vector_clock: mergedClock,
            asset_id: portable.id,
            identity_fingerprint: identityFingerprint ?? remoteMeta.identity_fingerprint
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
