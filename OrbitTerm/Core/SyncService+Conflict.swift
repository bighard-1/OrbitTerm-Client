import Foundation

@MainActor
extension SyncService {
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
                await SyncQueue.shared.enqueueDelete(assetID: server.id, request: request, accountID: accountID, reason: "waiting_for_login")
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
                    await SyncQueue.shared.enqueueDelete(assetID: server.id, request: request, accountID: accountID, reason: OperationRecoveryMapper.sync(error).diagnosticCode)
                    queuedCount += 1
                    continue
                }
                if isMissingOrUnsupportedTombstoneAPI(error),
                   let masterPassword,
                   await deleteLegacyRemoteConfig(
                    server,
                    token: token,
                    masterPassword: masterPassword,
                    accountID: accountID
                   ) {
                    DeletedServerRegistry.shared.clear(server.id)
                    syncedCount += 1
                    continue
                }
                await SyncQueue.shared.enqueueDelete(assetID: server.id, request: request, accountID: accountID, reason: OperationRecoveryMapper.sync(error).diagnosticCode)
                queuedCount += 1
            }
        }

        if queuedCount > 0 {
            lastSyncMessage = "已本地删除，\(queuedCount) 条删除任务将在后台重试"
        } else {
            lastSyncMessage = "已同步删除 \(syncedCount) 条云端资产，可在最近删除中恢复"
        }
    }

    func deleteLegacyRemoteConfig(
        _ server: ServerEntry,
        token: String?,
        masterPassword: String,
        accountID: String
    ) async -> Bool {
        guard let token else { return false }
        do {
            let remoteItems = try await network.pullConfigs(token: token)
            let v2RootKey = try prepareV2RootKeyIfRequired(
                for: remoteItems,
                masterPassword: masterPassword,
                accountID: accountID
            )
            for item in remoteItems {
                guard let portable = try? await decryptPortableBackground(
                    item,
                    masterPassword: masterPassword,
                    v2RootKey: v2RootKey
                ),
                      portable.id == server.id.uuidString else { continue }
                try await network.deleteConfig(id: item.id)
                return true
            }
            return false
        } catch {
            return false
        }
    }

    func isUnauthorized(_ error: Error) -> Bool {
        guard let networkError = error as? NetworkService.NetworkError else { return false }
        if case .unauthorized = networkError { return true }
        return false
    }

    func isMissingOrUnsupportedTombstoneAPI(_ error: Error) -> Bool {
        guard let networkError = error as? NetworkService.NetworkError else { return false }
        switch networkError {
        case .unexpectedStatus(404):
            return true
        case .httpStatus(404, _):
            return true
        default:
            return false
        }
    }

    func deleteRemoteConfigsInBackground(ids: [UInt]) {
        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else { return }
        Task(priority: .background) { [network] in
            for id in uniqueIDs {
                try? await network.deleteConfig(id: id)
            }
        }
    }

    nonisolated static func shouldPrefer(
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

    func resolveConflictAndRetry(
        token: String,
        masterPassword: String,
        accountID: String,
        localPortable: PortableServerConfig,
        fallbackPayload: UploadConfigRequest
    ) async -> Bool {
        do {
            let remoteItems = try await network.pullConfigs(token: token)
            let v2RootKey = try prepareV2RootKeyIfRequired(
                for: remoteItems,
                masterPassword: masterPassword,
                accountID: accountID
            )
            let decoded = remoteItems.compactMap { item -> (UploadConfigData, PortableServerConfig)? in
                guard let portable = try? Self.decryptPortableStatic(
                    item,
                    masterPassword: masterPassword,
                    v2RootKey: v2RootKey
                ) else { return nil }
                return (item, portable)
            }

            guard let target = decoded.first(where: { $0.1.id == localPortable.id }) else {
                await SyncQueue.shared.enqueueUpload(payload: fallbackPayload, accountID: accountID, reason: "conflict_pull_missing")
                lastSyncMessage = "冲突处理失败：未找到云端同名配置"
                return false
            }

            let remoteMeta = target.0
            let remotePortable = target.1
            let basePortable = shadowStore.read(id: localPortable.id, accountID: accountID)

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
                    shadowStore.save(merged, accountID: accountID)
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
                    shadowStore.save(localPortable, accountID: accountID)
                    lastSyncMessage = "已保留本地修改并覆盖云端"
                    return true
                case .keepCloud:
                    shadowStore.save(remotePortable, accountID: accountID)
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
                    shadowStore.save(localPortable, accountID: accountID)
                    lastSyncMessage = "已保留本地修改并覆盖云端"
                    return true
                case .keepCloud:
                    shadowStore.save(remotePortable, accountID: accountID)
                    lastSyncMessage = "已保留云端版本，本地修改未覆盖"
                    return true
                }
            }
        } catch {
            recordSyncFailure(error)
            return false
        }
    }

    func askUserConflictDecision(
        local: PortableServerConfig,
        remote: PortableServerConfig,
        conflictedFields: [ConflictField]
    ) async -> ConflictDecision {
        let localSummary = "名称: \(local.name)\n分组: \(local.group)\n标签: \(local.tags.joined(separator: "、"))\n主机: \(local.host):\(local.port)\n用户: \(local.username)"
        let cloudSummary = "名称: \(remote.name)\n分组: \(remote.group)\n标签: \(remote.tags.joined(separator: "、"))\n主机: \(remote.host):\(remote.port)\n用户: \(remote.username)"
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

    func mergedPortable(
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
            savedAtUnix: Int(Date().timeIntervalSince1970),
            tags: localChanged.contains(.tags) ? local.tags : remote.tags,
            jumpHost: localChanged.contains(.jumpHost) ? local.jumpHost : remote.jumpHost
        )
    }

    func changedFields(from base: SyncShadowSnapshot, to newer: PortableServerConfig) -> Set<ConflictField> {
        var changed = Set<ConflictField>()
        if base.name != newer.name { changed.insert(.name) }
        if base.group != newer.group { changed.insert(.group) }
        if base.tags != newer.tags { changed.insert(.tags) }
        if base.host != newer.host { changed.insert(.host) }
        if base.port != newer.port { changed.insert(.port) }
        if base.username != newer.username { changed.insert(.username) }
        if base.authMethod != newer.authMethod { changed.insert(.authMethod) }
        if base.networkDeviceProfile != newer.networkDeviceProfile { changed.insert(.networkDeviceProfile) }
        if base.allowPasswordFallback != newer.allowPasswordFallback { changed.insert(.allowPasswordFallback) }
        let current = shadowStore.snapshot(for: newer)
        if base.passwordDigest != current.passwordDigest { changed.insert(.password) }
        if base.privateKeyDigest != current.privateKeyDigest { changed.insert(.privateKeyContent) }
        if base.privateKeyPassphraseDigest != current.privateKeyPassphraseDigest { changed.insert(.privateKeyPassphrase) }
        if base.jumpHostDigest != current.jumpHostDigest { changed.insert(.jumpHost) }
        return changed
    }

    func buildPayload(
        portable: PortableServerConfig,
        masterPassword: String,
        remoteMeta: UploadConfigData,
        identityFingerprint: String?
    ) async throws -> UploadConfigRequest {
        let plain = try encodePortable(portable)
        let encrypted: Data
        if let scope = activeAccountScope, Self.isV2CipherWriteEnabled(scope: scope) {
            try orbitManager.prepareConfigRootKeyV2(masterPassword: masterPassword, accountScope: scope)
            encrypted = try orbitManager.encryptConfigV2(Data(plain.utf8))
        } else {
            encrypted = try orbitManager.encrypt(password: masterPassword, data: plain)
        }
        let mergedClock = Self.bumpClock(remoteMeta.vector_clock, actor: "client")
        return UploadConfigRequest(
            id: remoteMeta.id,
            encrypted_blob_base64: encrypted.base64EncodedString(),
            vector_clock: mergedClock,
            asset_id: portable.id,
            identity_fingerprint: identityFingerprint ?? remoteMeta.identity_fingerprint
        )
    }

    static func bumpClock(_ raw: String, actor: String) -> String {
        var map = (try? JSONDecoder().decode([String: Int].self, from: Data(raw.utf8))) ?? [:]
        map[actor] = (map[actor] ?? 0) + 1
        return encodeVectorClock(map)
    }

    static func encodeVectorClock(_ map: [String: Int]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    func encodePortable(_ portable: PortableServerConfig) throws -> String {
        let data = try JSONEncoder().encode(portable)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        return text
    }

    func decodePortable(from plaintext: String) throws -> PortableServerConfig {
        guard let data = plaintext.data(using: .utf8) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        return try JSONDecoder().decode(PortableServerConfig.self, from: data)
    }

    func enrichPortableWithCredentialVault(_ portable: PortableServerConfig) throws -> PortableServerConfig {
        guard let credentialUUID = UUID(uuidString: portable.credentialID),
              let credentials = try vault.read(for: credentialUUID) else {
            return portable
        }
        let jumpHost: PortableJumpHostConfiguration?
        if let configuredJumpHost = portable.jumpHost,
           let jumpConfiguration = configuredJumpHost.makeConfiguration(),
           let jumpCredentials = try vault.read(for: jumpConfiguration.credentialID) {
            jumpHost = PortableJumpHostConfiguration(
                configuration: jumpConfiguration,
                credentials: jumpCredentials
            )
        } else {
            jumpHost = portable.jumpHost
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
            savedAtUnix: portable.savedAtUnix,
            tags: portable.tags,
            jumpHost: jumpHost
        )
    }

    nonisolated static func decryptPortableStatic(
        _ item: UploadConfigData,
        masterPassword: String,
        v2RootKey: Data? = nil
    ) throws -> PortableServerConfig {
        guard let encrypted = Data(base64Encoded: item.encrypted_blob_base64) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        let plainData = try decryptBlob(
            password: masterPassword,
            encrypted: encrypted,
            v2RootKey: v2RootKey
        )
        guard let plainText = String(data: plainData, encoding: .utf8),
              let portableData = plainText.data(using: .utf8) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        return try JSONDecoder().decode(PortableServerConfig.self, from: portableData)
    }

    func decryptPortableBackground(
        _ item: UploadConfigData,
        masterPassword: String,
        v2RootKey: Data? = nil
    ) async throws -> PortableServerConfig {
        try await Task.detached(priority: .utility) {
            try Self.decryptPortableStatic(item, masterPassword: masterPassword, v2RootKey: v2RootKey)
        }.value
    }

    nonisolated static func decryptBlob(
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
            guard let resultPtr else {
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

    func isConflict(_ error: Error) -> Bool {
        if let net = error as? NetworkService.NetworkError {
            switch net {
            case let .unexpectedStatus(code):
                return code == 409
            case .httpStatus(409, _):
                return true
            default:
                return false
            }
        }
        return false
    }
}
