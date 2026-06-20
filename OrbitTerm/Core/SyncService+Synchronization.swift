import Foundation

@MainActor
extension SyncService {
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

    func pullLegacyAndApplyConfigs(
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
                shadowAuthenticationKey: shadowStore.authenticationKey,
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

    func pullIncrementalAndApplyConfigs(
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
                shadowAuthenticationKey: shadowStore.authenticationKey,
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

    func publishMigratedLocalTombstone(
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

    nonisolated static func makeServer(from portable: PortableServerConfig) throws -> ServerEntry {
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

    nonisolated static func makeCredentials(from portable: PortableServerConfig) -> ServerCredentials {
        ServerCredentials(
            password: portable.password,
            privateKeyContent: portable.privateKeyContent,
            privateKeyPassphrase: portable.privateKeyPassphrase
        )
    }

    func preparePullResultBackground(
        _ remoteItems: [UploadConfigData],
        masterPassword: String,
        shadowSnapshot: [String: SyncShadowSnapshot],
        shadowAuthenticationKey: Data,
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
                let currentSnapshot = SyncShadowSnapshot(
                    item.portable,
                    authenticationKey: shadowAuthenticationKey
                )
                let shouldCheckCredentials = shadowSnapshot[item.portable.id] != currentSnapshot
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

}
