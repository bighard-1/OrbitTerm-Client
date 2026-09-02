import Foundation

private struct IncrementalSyncPullResult {
    let receivedRemoteChanges: Bool
}

@MainActor
extension SyncService {
    func pullAndApplyConfigs(
        token: String,
        masterPassword: String,
        store: ServerStore,
        accountID: String,
        incremental: Bool = false,
        silentStart: Bool = false,
        forceFullInventory: Bool = false
    ) async -> Bool {
        guard store.isActiveAccount(accountID) else { return false }
        updateSyncPresentation(.syncing, detail: "正在同步加密数据")
        let span = PerformanceSignpost.begin(.syncRoundTrip)
        defer { span.finish() }
        let completed: Bool
        do {
            if forceFullInventory {
                completed = await pullLegacyAndApplyConfigs(
                    token: token,
                    masterPassword: masterPassword,
                    store: store,
                    accountID: accountID,
                    incremental: incremental,
                    silentStart: silentStart
                )
            } else {
                let incrementalResult = try await pullIncrementalAndApplyConfigs(
                    token: token,
                    masterPassword: masterPassword,
                    store: store,
                    accountID: accountID,
                    incremental: incremental,
                    silentStart: silentStart
                )

                if SyncPullRecoveryPolicy.shouldPerformFullPull(
                    localAssetCount: store.servers.count,
                    incrementalResponseHadChanges: incrementalResult.receivedRemoteChanges
                ) {
                    completed = await pullLegacyAndApplyConfigs(
                        token: token,
                        masterPassword: masterPassword,
                        store: store,
                        accountID: accountID,
                        incremental: incremental,
                        silentStart: silentStart
                    )
                } else {
                    completed = true
                }
            }
        } catch {
            if isMissingOrUnsupportedTombstoneAPI(error) {
                completed = await pullLegacyAndApplyConfigs(
                    token: token,
                    masterPassword: masterPassword,
                    store: store,
                    accountID: accountID,
                    incremental: incremental,
                    silentStart: silentStart
                )
            } else {
                recordSyncFailure(error)
                return false
            }
        }
        if completed {
            clearSyncRecoveryPresentation()
            var auxiliaryFailureDetails: [String] = []
            let keyLibrarySynchronized = await synchronizeSshKeyLibrary(
                token: token,
                masterPassword: masterPassword,
                accountID: accountID,
                store: store
            )
            if !keyLibrarySynchronized {
                auxiliaryFailureDetails.append("SSH 密钥库同步暂不可用，本机变更已安全保留")
            }
            do {
                try PortForwardProfileStore.shared.activate(username: accountID)
                try await PortForwardProfileStore.shared.synchronize(
                    token: token,
                    masterPassword: masterPassword,
                    accountID: accountID,
                    network: network,
                    orbitManager: orbitManager
                )
            } catch {
                lastSyncMessage = "资产已同步；端口映射配置将在下次重试"
                auxiliaryFailureDetails.append("端口映射配置将在下次重试")
            }
            await attemptConfigCipherMigrationIfNeeded(
                token: token,
                masterPassword: masterPassword,
                accountID: accountID,
                store: store,
                isExplicitFullSync: forceFullInventory
            )
            let completionPresentation = SyncPresentationState.afterCompletedPull(
                detail: lastSyncMessage,
                auxiliaryFailureDetails: auxiliaryFailureDetails
            )
            updateSyncPresentation(
                completionPresentation.phase,
                detail: completionPresentation.detail
            )
        }
        return completed
    }

    /// Explicitly publishes or refreshes the reusable SSH-key library after a
    /// key-management mutation, without requiring an additional asset edit.
    func synchronizeSshKeyLibrary(
        token: String,
        masterPassword: String,
        accountID: String,
        store: ServerStore
    ) async -> Bool {
        guard store.isActiveAccount(accountID) else { return false }
        do {
            try SshKeySyncStore.shared.activate(username: accountID)
            try await SshKeySyncStore.shared.synchronize(
                token: token,
                masterPassword: masterPassword,
                accountID: accountID,
                network: network,
                orbitManager: orbitManager,
                serverStore: store,
                credentialVault: vault
            )
            return true
        } catch {
            lastSyncMessage = "SSH 密钥库同步暂不可用，本机变更已安全保留"
            return false
        }
    }

    /// A migration endpoint is an optional rollout capability. Its absence or
    /// a concurrent cloud edit must never turn an otherwise successful normal
    /// sync into a failure; the next completed sync retries from a new exact
    /// snapshot.
    private func attemptConfigCipherMigrationIfNeeded(
        token: String,
        masterPassword: String,
        accountID: String,
        store: ServerStore,
        isExplicitFullSync: Bool
    ) async {
        guard store.isActiveAccount(accountID),
              let scope = AccountScope(username: accountID),
              activeAccountScope == scope else { return }
        guard SyncConfigCipherMigrationPolicy.shouldAttempt(
            hasCompletedMarker: Self.isV2CipherWriteEnabled(scope: scope),
            isExplicitFullSync: isExplicitFullSync,
            cooldownAllowsRetry: shouldAttemptV2Migration(for: scope)
        ) else { return }
        recordV2MigrationAttempt(for: scope)
        do {
            let result = try await migrateRemoteConfigCryptoToV2(
                token: token,
                masterPassword: masterPassword,
                accountID: accountID
            )
            lastSyncMessage = SyncConfigCipherMigrationPolicy.userMessage(for: result)
        } catch {
            // The full sync has already succeeded. Keep that success intact at
            // the data layer while making the deferred migration observable
            // through an app-owned, redacted recovery code.
            lastSyncMessage = SyncConfigCipherMigrationPolicy.userMessage(
                for: .pendingRetry(OperationRecoveryMapper.sync(error).diagnosticCode)
            )
        }
    }

    func pullLegacyAndApplyConfigs(
        token: String,
        masterPassword: String,
        store: ServerStore,
        accountID: String,
        incremental: Bool,
        silentStart: Bool
    ) async -> Bool {
        do {
            if !silentStart {
                lastSyncMessage = "正在后台同步..."
            }
            let remotePullSpan = PerformanceSignpost.begin(.syncRemotePull)
            let remoteItems: [UploadConfigData]
            do {
                let activeItems = try await network.pullConfigs(token: token)
                let trashItems = try await pullDeletedRemoteConfigs()
                remoteItems = SyncPullRecoveryPolicy.mergeRemoteInventory(
                    activeItems: activeItems,
                    trashItems: trashItems,
                    assetID: { $0.asset_id },
                    recordID: { String($0.id) }
                )
                remotePullSpan.finish()
            } catch {
                remotePullSpan.cancel()
                throw error
            }
            guard store.isActiveAccount(accountID) else { return false }
            if remoteItems.isEmpty {
                let localAssetIDs = Set(store.servers.map { $0.id.uuidString.lowercased() })
                let pendingIDs = Set(
                    SyncPullRecoveryPolicy.localAssetIDsPendingExplicitPublication(
                        localAssetIDs: localAssetIDs,
                        cloudKnownAssetIDs: []
                    ).compactMap(UUID.init(uuidString:))
                )
                setPendingLocalAssetRecoveryIDs(pendingIDs)
                lastSyncMessage = pendingIDs.isEmpty
                    ? "拉取完成: 云端暂无配置"
                    : "云端暂无配置；本地有 \(pendingIDs.count) 项资产尚未发布"
                return true
            }

            // Explicit "立即双向同步" uses this full-inventory path.  Unlike an
            // incremental page, a full response can contain tombstones beside
            // active records; applying only the active records would leave a
            // deleted server visible on this device indefinitely.  Apply those
            // tombstones before any active-record merge and keep their metadata
            // so an older local copy is never republished as a new asset.
            let deletedRemoteItems = remoteItems.filter { ($0.state ?? "active") != "active" }
            var fullPullDeletedCount = 0
            for item in deletedRemoteItems {
                guard let rawID = item.asset_id, let assetID = UUID(uuidString: rawID) else { continue }
                store.applyRemoteDeletion(assetID, accountID: accountID)
                SyncMetadataStore.shared.saveAsset(item, fallbackAssetID: assetID, accountID: accountID)
                fullPullDeletedCount += 1
            }
            let activeRemoteItems = remoteItems.filter { ($0.state ?? "active") == "active" }

            let shadowSnapshot = shadowStore.readAll(accountID: accountID)
            let tombstoneSnapshot = DeletedServerRegistry.shared.snapshot()
            let v2RootKey = try prepareV2RootKeyIfRequired(
                for: activeRemoteItems,
                masterPassword: masterPassword,
                accountID: accountID
            )
            let preparationSpan = PerformanceSignpost.begin(.syncPreparation)
            let preparation: SyncPullPreparation
            do {
                preparation = try await preparePullResultBackground(
                    activeRemoteItems,
                    masterPassword: masterPassword,
                    v2RootKey: v2RootKey,
                    shadowSnapshot: shadowSnapshot,
                    shadowAuthenticationKey: shadowStore.authenticationKey,
                    tombstoneSnapshot: tombstoneSnapshot
                )
                preparationSpan.finish()
            } catch {
                preparationSpan.cancel()
                throw error
            }

            let servers = preparation.items.map(\.server)
            let portables = preparation.items.map(\.portable)
            let activeRemoteAssetIDs = Set(activeRemoteItems.compactMap { item -> String? in
                guard let id = item.asset_id?.lowercased(),
                      UUID(uuidString: id) != nil else {
                    return nil
                }
                return id
            })
            let knownRemoteAssetIDs = Set(remoteItems.compactMap { item -> String? in
                guard let id = item.asset_id?.lowercased(), UUID(uuidString: id) != nil else {
                    return nil
                }
                return id
            })
            if SyncPullRecoveryPolicy.remoteAssetsRequireMasterPasswordRecovery(
                remoteAssetCount: activeRemoteAssetIDs.count,
                decodedRemoteAssetCount: servers.count
            ), preparation.tombstoneSkipped == 0 {
                setPendingLocalAssetRecoveryIDs([])
                setSyncRecoveryPresentation(OperationRecoveryMapper.syncMasterPasswordMismatch())
                return false
            }
            let localAssetIDs = Set(store.servers.map { $0.id.uuidString.lowercased() })
            let pendingIDs = Set(
                SyncPullRecoveryPolicy.localAssetIDsPendingExplicitPublication(
                    localAssetIDs: localAssetIDs,
                    cloudKnownAssetIDs: knownRemoteAssetIDs
                ).compactMap(UUID.init(uuidString:))
            )
            if activeRemoteAssetIDs.isEmpty && servers.isEmpty {
                setPendingLocalAssetRecoveryIDs(pendingIDs)
                lastSyncMessage = pendingIDs.isEmpty
                    ? "拉取完成：云端未发现资产"
                    : "云端未发现资产；本地有 \(pendingIDs.count) 项资产尚未发布"
                return true
            }
            let appliedServerCount: Int
            if incremental {
                appliedServerCount = await store.applySyncedServersIncrementally(
                    servers,
                    accountID: accountID,
                    batchSize: 6
                )
            } else {
                let metadataChanged = !store.containsSameServers(servers, accountID: accountID)
                if metadataChanged {
                    store.applySyncedServers(servers, accountID: accountID)
                }
                appliedServerCount = metadataChanged ? servers.count : 0
            }
            shadowStore.saveMany(portables, accountID: accountID)
            shadowStore.retainOnly(
                assetIDs: Set(store.servers.map { $0.id.uuidString }),
                accountID: accountID
            )
            setPendingLocalAssetRecoveryIDs(pendingIDs)

            // A complete reconciliation can discover an old active cloud
            // record for an asset that this Mac deleted while deletion sync
            // was unavailable.  Skipping that record locally is insufficient:
            // another device would continue to see it.  Promote the durable
            // local deletion marker to an authenticated remote tombstone before
            // removing any duplicate records, so every platform observes the
            // same authoritative deletion on its next full reconciliation.
            for tombstone in preparation.tombstonedRemotes {
                await publishMigratedLocalTombstone(
                    assetID: tombstone.assetID,
                    remote: tombstone.remote,
                    token: token,
                    accountID: accountID
                )
            }

            // Do not permanently delete the record just converted into a
            // tombstone. Other devices need that record to observe the delete.
            let migratedRecordIDs = Set(preparation.tombstonedRemotes.map { $0.remote.id })
            deleteRemoteConfigsInBackground(
                ids: SyncPullRecoveryPolicy.remoteRecordIDsSafeToPurge(
                    candidateRecordIDs: Set(preparation.remoteConfigIDsToDelete),
                    migratedTombstoneRecordIDs: migratedRecordIDs
                )
            )

            let changedCount = preparation.credentialWriteCount + appliedServerCount + fullPullDeletedCount
            if changedCount == 0, pendingIDs.isEmpty {
                lastSyncMessage = "后台同步完成: 云端无变化"
            } else {
                let ignored = preparation.skipped + preparation.tombstoneSkipped + preparation.duplicateSkipped
                let pendingText = pendingIDs.isEmpty ? "" : "，本地待发布 \(pendingIDs.count) 条"
                lastSyncMessage = "后台同步完成: 更新 \(appliedServerCount) 条，删除 \(fullPullDeletedCount) 条，凭据变更 \(preparation.credentialWriteCount) 条，忽略 \(ignored) 条\(pendingText)"
            }
            return !servers.isEmpty || preparation.skipped == 0
        } catch {
            recordSyncFailure(error)
            return false
        }
    }

    /// The full inventory endpoint exposes active records only. Fetching the
    /// trash separately is required to apply deletions made on another device.
    private func pullDeletedRemoteConfigs() async throws -> [UploadConfigData] {
        var items: [UploadConfigData] = []
        var offset = 0
        while true {
            let page = try await network.pullTrash(limit: 500, offset: offset)
            items.append(contentsOf: page.items)
            offset += page.items.count
            if page.items.isEmpty || offset >= page.total { return items }
        }
    }

    private func pullIncrementalAndApplyConfigs(
        token: String,
        masterPassword: String,
        store: ServerStore,
        accountID: String,
        incremental: Bool,
        silentStart: Bool
    ) async throws -> IncrementalSyncPullResult {
        guard store.isActiveAccount(accountID) else {
            return IncrementalSyncPullResult(receivedRemoteChanges: false)
        }
        if !silentStart {
            lastSyncMessage = "正在后台增量同步..."
        }

        let metadata = SyncMetadataStore.shared
        var cursor = metadata.cursor(accountID: accountID)
        var resetAttempted = false
        var appliedCount = 0
        var deletedCount = 0
        var credentialCount = 0
        var receivedRemoteChanges = false

        while true {
            let remotePullSpan = PerformanceSignpost.begin(.syncRemotePull)
            let page: SyncPullData
            do {
                page = try await network.pullConfigChanges(
                    cursor: cursor,
                    limit: OperationResourceBudget.syncIncrementalPageSize
                )
                remotePullSpan.finish()
            } catch {
                remotePullSpan.cancel()
                throw error
            }
            guard store.isActiveAccount(accountID) else {
                return IncrementalSyncPullResult(receivedRemoteChanges: receivedRemoteChanges)
            }
            if page.reset_required {
                guard !resetAttempted else {
                    throw NetworkService.NetworkError.server("同步游标连续失效，请稍后重试")
                }
                metadata.resetCursor(accountID: accountID)
                cursor = 0
                resetAttempted = true
                continue
            }

            receivedRemoteChanges = receivedRemoteChanges || !page.items.isEmpty

            let remoteDeletes = page.items.filter { ($0.state ?? "active") != "active" }
            for item in remoteDeletes {
                guard let rawID = item.asset_id, let assetID = UUID(uuidString: rawID) else { continue }
                store.applyRemoteDeletion(assetID, accountID: accountID)
                metadata.saveAsset(item, fallbackAssetID: assetID, accountID: accountID)
                deletedCount += 1
            }

            let remoteActive = page.items.filter { ($0.state ?? "active") == "active" }
            let v2RootKey = try prepareV2RootKeyIfRequired(
                for: remoteActive,
                masterPassword: masterPassword,
                accountID: accountID
            )
            let preparationSpan = PerformanceSignpost.begin(.syncPreparation)
            let preparation: SyncPullPreparation
            do {
                preparation = try await preparePullResultBackground(
                    remoteActive,
                    masterPassword: masterPassword,
                    v2RootKey: v2RootKey,
                    shadowSnapshot: shadowStore.readAll(accountID: accountID),
                    shadowAuthenticationKey: shadowStore.authenticationKey,
                    tombstoneSnapshot: DeletedServerRegistry.shared.snapshot()
                )
                preparationSpan.finish()
            } catch {
                preparationSpan.cancel()
                throw error
            }

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
                changed = await store.applySyncedServersIncrementally(
                    servers,
                    accountID: accountID,
                    batchSize: 6
                )
            } else {
                let metadataChanged = !store.containsSameServers(servers, accountID: accountID)
                if metadataChanged {
                    store.applySyncedServers(servers, accountID: accountID)
                }
                changed = metadataChanged ? servers.count : 0
            }
            appliedCount += changed
            credentialCount += preparation.credentialWriteCount
            shadowStore.saveMany(preparation.items.map(\.portable), accountID: accountID)
            shadowStore.retainOnly(
                assetIDs: Set(store.servers.map { $0.id.uuidString }),
                accountID: accountID
            )
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
        return IncrementalSyncPullResult(receivedRemoteChanges: receivedRemoteChanges)
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
                await SyncQueue.shared.enqueueUpload(payload: bindPayload, accountID: accountID, reason: OperationRecoveryMapper.sync(error).diagnosticCode)
                let deleteClock = metadata.incrementVectorClock(bindClock)
                let deleteRequest = AssetMutationRequest(
                    deviceID: metadata.deviceID,
                    vectorClock: deleteClock
                )
                await SyncQueue.shared.enqueueDelete(assetID: assetID, request: deleteRequest, accountID: accountID, reason: "waiting_for_asset_id_binding")
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
            await SyncQueue.shared.enqueueDelete(assetID: assetID, request: deleteRequest, accountID: accountID, reason: OperationRecoveryMapper.sync(error).diagnosticCode)
        }
    }

    func loadRecentlyDeleted(
        masterPassword: String,
        accountID: String
    ) async throws -> [RecentlyDeletedAsset] {
        let trash = try await network.pullTrash(limit: 500)
        let v2RootKey = try prepareV2RootKeyIfRequired(
            for: trash.items,
            masterPassword: masterPassword,
            accountID: accountID
        )
        let metadata = SyncMetadataStore.shared
        var results: [RecentlyDeletedAsset] = []

        for remote in trash.items {
            if let rawAssetID = remote.asset_id, let assetID = UUID(uuidString: rawAssetID) {
                metadata.saveAsset(remote, fallbackAssetID: assetID, accountID: accountID)
            }
            do {
                let portable = try await decryptPortableBackground(
                    remote,
                    masterPassword: masterPassword,
                    v2RootKey: v2RootKey
                )
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
        // Validate the encrypted route before mutating its remote deletion
        // state. An invalid jump descriptor must not turn into a direct route
        // or restore a remote asset that the client cannot safely use.
        let server = try Self.makeServer(from: portable)
        let credentials = Self.makeCredentials(from: portable)

        do {
            let restored = try await network.restoreAsset(assetID: assetID, request: request)

            // 先确认 Keychain 写入成功，再把普通资产元数据暴露给 UI。
            try vault.save(credentials, for: server.credentialID)
            if let jumpHost = server.jumpHost,
               let jumpHostCredentials = Self.makeJumpHostCredentials(from: portable) {
                try vault.save(jumpHostCredentials, for: jumpHost.credentialID)
            }
            store.addOrUpdate(server)
            shadowStore.save(portable, accountID: accountID)
            metadata.saveAsset(restored, fallbackAssetID: assetID, accountID: accountID)
            DeletedServerRegistry.shared.clear(assetID)
            lastSyncMessage = "已恢复 \(server.name)"
            return .completed
        } catch {
            if NetworkService.isRetriableNetworkError(error) || isUnauthorized(error) {
                await SyncQueue.shared.enqueueRestore(assetID: assetID, request: request, accountID: accountID, reason: OperationRecoveryMapper.sync(error).diagnosticCode)
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
                await SyncQueue.shared.enqueuePurge(assetID: assetID, request: request, accountID: accountID, reason: OperationRecoveryMapper.sync(error).diagnosticCode)
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
        guard let transport = ServerTransportProtocol(rawValue: portable.transport) else {
            throw NetworkService.NetworkError.server("资产传输协议不受支持")
        }
        let credentialID = UUID(uuidString: portable.credentialID) ?? serverID
        let jumpHost: JumpHostConfiguration?
        if let portableJumpHost = portable.jumpHost {
            guard portable.transport == ServerTransportProtocol.ssh.rawValue,
                  let configuration = portableJumpHost.makeConfiguration(),
                  configuration.credentialID != credentialID,
                  portableJumpHost.hasAuthenticationMaterial else {
                throw NetworkService.NetworkError.server("跳板机加密配置无效")
            }
            jumpHost = configuration
        } else {
            jumpHost = nil
        }
        return ServerEntry(
            id: serverID,
            name: portable.name,
            group: portable.group,
            tags: portable.tags,
            host: portable.host,
            port: portable.port,
            username: portable.username,
            authMethod: portable.authMethod == ServerAuthMethod.key.rawValue ? .key : .password,
            transport: transport,
            networkDeviceProfile: NetworkDeviceProfile(rawValue: portable.networkDeviceProfile) ?? .auto,
            allowPasswordFallback: portable.allowPasswordFallback,
            credentialID: credentialID,
            jumpHost: jumpHost,
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

    nonisolated static func makeJumpHostCredentials(
        from portable: PortableServerConfig
    ) -> ServerCredentials? {
        portable.jumpHost?.credentials
    }

    func preparePullResultBackground(
        _ remoteItems: [UploadConfigData],
        masterPassword: String,
        v2RootKey: Data?,
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
                    let portable = try Self.decryptPortableStatic(
                        item,
                        masterPassword: masterPassword,
                        v2RootKey: v2RootKey
                    )
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
                    guard let transport = ServerTransportProtocol(rawValue: portable.transport) else {
                        skipped += 1
                        continue
                    }
                    let credentialID = UUID(uuidString: portable.credentialID) ?? serverID
                    let credentials = ServerCredentials(
                        password: portable.password,
                        privateKeyContent: portable.privateKeyContent,
                        privateKeyPassphrase: portable.privateKeyPassphrase
                    )
                    let jumpHost: JumpHostConfiguration?
                    if let portableJumpHost = portable.jumpHost {
                        guard portable.transport == ServerTransportProtocol.ssh.rawValue,
                              let configuration = portableJumpHost.makeConfiguration(),
                              configuration.credentialID != credentialID,
                              portableJumpHost.hasAuthenticationMaterial else {
                            skipped += 1
                            continue
                        }
                        jumpHost = configuration
                    } else {
                        jumpHost = nil
                    }

                    let server = ServerEntry(
                        id: serverID,
                        name: portable.name,
                        group: portable.group,
                        tags: portable.tags,
                        host: portable.host,
                        port: portable.port,
                        username: portable.username,
                        authMethod: portable.authMethod == ServerAuthMethod.key.rawValue ? .key : .password,
                        transport: transport,
                        networkDeviceProfile: NetworkDeviceProfile(rawValue: portable.networkDeviceProfile) ?? .auto,
                        allowPasswordFallback: portable.allowPasswordFallback,
                        credentialID: credentialID,
                        jumpHost: jumpHost,
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
                if let jumpHost = item.server.jumpHost,
                   let jumpHostCredentials = item.portable.jumpHost?.credentials {
                    let existingJumpCredentials = try? vault.read(for: jumpHost.credentialID)
                    if shouldCheckCredentials || existingJumpCredentials == nil || existingJumpCredentials != jumpHostCredentials {
                        try vault.save(jumpHostCredentials, for: jumpHost.credentialID)
                        credentialWriteCount += 1
                    }
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
