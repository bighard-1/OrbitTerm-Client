import CryptoKit
import Foundation

@MainActor
final class SyncService: ObservableObject {
    static let shared = SyncService()

    @Published var lastSyncMessage: String = "尚未同步"
    /// Typed, redacted recovery state for the most recent failed sync.  The
    /// UI must use this instead of parsing `lastSyncMessage`.
    @Published private(set) var lastRecoveryPresentation: OperationRecoveryPresentation?
    /// Counts and a non-reversible account marker for support diagnosis. Never
    /// includes asset names, UUIDs, credentials, or the access token itself.
    @Published private(set) var lastInventoryDiagnostic: String = ""
    @Published var pendingConflictPrompt: SyncConflictPrompt?
    @Published private(set) var pendingLocalAssetRecoveryIDs: Set<UUID> = []

    var pendingLocalAssetRecoveryCount: Int {
        pendingLocalAssetRecoveryIDs.count
    }

    private(set) var activeAccountScope: AccountScope?
    private var lastV2MigrationAttemptAt: [String: Date] = [:]


    let network: NetworkService
    let orbitManager: OrbitManager
    let vault: CredentialVault
    let shadowStore = SyncShadowStore()
    var conflictContinuation: CheckedContinuation<ConflictDecision, Never>?

    init(network: NetworkService = .shared, orbitManager: OrbitManager? = nil, vault: CredentialVault = .shared) {
        self.network = network
        self.orbitManager = orbitManager ?? OrbitManager()
        self.vault = vault
    }

    /// Clears account-specific presentation and releases a pending conflict
    /// continuation before a different account can become active.
    func activateAccount(username: String) {
        let nextScope = AccountScope(username: username)
        guard activeAccountScope != nextScope else { return }
        orbitManager.clearConfigRootKeyV2()
        resetAccountPresentation(resolvingConflictAs: .keepCloud)
        activeAccountScope = nextScope
    }

    func deactivateAccount() {
        orbitManager.clearConfigRootKeyV2()
        resetAccountPresentation(resolvingConflictAs: .keepCloud)
        activeAccountScope = nil
    }

    func clearTransientConfigCrypto() {
        orbitManager.clearConfigRootKeyV2()
    }

    /// The flag contains only an opaque account namespace, never a key or
    /// password. It is set exclusively after an atomic server migration and a
    /// full local decrypt verification.
    nonisolated static func isV2CipherWriteEnabled(scope: AccountScope) -> Bool {
        UserDefaults.standard.bool(forKey: "OrbitTerm.Sync.ConfigCipherV2." + scope.storageIdentifier)
    }

    nonisolated static func markV2CipherWriteEnabled(scope: AccountScope) {
        UserDefaults.standard.set(true, forKey: "OrbitTerm.Sync.ConfigCipherV2." + scope.storageIdentifier)
    }

    /// V2 is selected only from its authenticated format header. The account
    /// root is prepared once per pull and copied into the bounded background
    /// decode job; V1-only pulls never pay this extra Argon2id operation.
    func prepareV2RootKeyIfRequired(
        for items: [UploadConfigData],
        masterPassword: String,
        accountID: String
    ) throws -> Data? {
        guard items.contains(where: { item in
            guard let blob = Data(base64Encoded: item.encrypted_blob_base64) else { return false }
            return OrbitManager.isV2ConfigBlob(blob)
        }) else {
            return nil
        }
        guard let scope = AccountScope(username: accountID), activeAccountScope == scope else {
            throw NetworkService.NetworkError.decodeFailed
        }
        try orbitManager.prepareConfigRootKeyV2(masterPassword: masterPassword, accountScope: scope)
        return try orbitManager.configRootKeyV2ForBackground(scope: scope)
    }

    private func resetAccountPresentation(resolvingConflictAs choice: ConflictChoice) {
        conflictContinuation?.resume(returning: ConflictDecision(choice: choice))
        conflictContinuation = nil
        pendingConflictPrompt = nil
        pendingLocalAssetRecoveryIDs = []
        lastRecoveryPresentation = nil
        lastInventoryDiagnostic = ""
        lastSyncMessage = "尚未同步"
    }

    func shouldAttemptV2Migration(for scope: AccountScope, now: Date = Date()) -> Bool {
        guard let lastAttempt = lastV2MigrationAttemptAt[scope.storageIdentifier] else { return true }
        return now.timeIntervalSince(lastAttempt) >= 15 * 60
    }

    func recordV2MigrationAttempt(for scope: AccountScope, at date: Date = Date()) {
        lastV2MigrationAttemptAt[scope.storageIdentifier] = date
    }

    func chooseConflict(_ choice: ConflictChoice) {
        conflictContinuation?.resume(returning: ConflictDecision(choice: choice))
        conflictContinuation = nil
        pendingConflictPrompt = nil
    }

    func setPendingLocalAssetRecoveryIDs(_ ids: Set<UUID>) {
        pendingLocalAssetRecoveryIDs = ids
    }

    func recordSyncFailure(_ error: Error) {
        // View/task lifecycle cancellation is not a connectivity failure.  In
        // particular, iOS cancels an in-flight automatic sync when the app is
        // backgrounded or its root view is replaced during account changes.
        // Keeping the previous success state is less misleading than showing
        // a persistent "network unavailable" banner for that expected event.
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return
        }
        setSyncRecoveryPresentation(OperationRecoveryMapper.sync(error))
    }

    func setSyncRecoveryPresentation(_ presentation: OperationRecoveryPresentation) {
        guard presentation.domain == .sync else { return }
        lastRecoveryPresentation = presentation
        lastSyncMessage = "\(presentation.title)：\(presentation.message)"
    }

    func clearSyncRecoveryPresentation() {
        lastRecoveryPresentation = nil
    }

    func refreshInventoryDiagnostic(token: String, store: ServerStore) async {
        do {
            let remoteItems = try await network.pullConfigs(token: token)
            let remoteAssetIDs = Set(remoteItems.compactMap { item -> String? in
                guard (item.state ?? "active") == "active",
                      let rawID = item.asset_id?.lowercased(),
                      UUID(uuidString: rawID) != nil else {
                    return nil
                }
                return rawID
            })
            let localAssetIDs = Set(store.servers.map { $0.id.uuidString.lowercased() })
            let remoteOnly = remoteAssetIDs.subtracting(localAssetIDs).count
            let localOnly = localAssetIDs.subtracting(remoteAssetIDs).count
            let nonAssetRecords = remoteItems.count - remoteAssetIDs.count
            lastInventoryDiagnostic = "账户指纹 \(accountFingerprint(from: token))；云端资产 \(remoteAssetIDs.count)；本地资产 \(localAssetIDs.count)；待导入 \(remoteOnly)；待发布 \(localOnly)；其他加密记录 \(nonAssetRecords)"
        } catch {
            lastInventoryDiagnostic = "同步诊断读取失败：\(OperationRecoveryMapper.sync(error).diagnosticCode)"
        }
    }

    private func accountFingerprint(from token: String) -> String {
        let payload = token.split(separator: ".").dropFirst().first.map(String.init) ?? ""
        let padded = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .padding(toLength: ((payload.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        guard let data = Data(base64Encoded: padded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userID = object["uid"] else {
            return "不可用"
        }
        let digest = SHA256.hash(data: Data("OrbitTerm.Sync.Account.v1|\(userID)".utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Publishes only local assets the latest full inventory did not contain,
    /// and only after the user explicitly confirms that recovery.
    func publishPendingLocalAssets(
        token: String,
        masterPassword: String,
        store: ServerStore,
        accountID: String
    ) async {
        let recoveryIDs = pendingLocalAssetRecoveryIDs
        let servers = store.servers.filter { recoveryIDs.contains($0.id) }
        guard !servers.isEmpty else {
            setPendingLocalAssetRecoveryIDs([])
            lastSyncMessage = "本地暂无可发布资产"
            return
        }

        lastSyncMessage = "正在发布本地资产到云端..."
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var published = 0
        var skipped = 0
        var unpublishedIDs: Set<UUID> = []
        let baseTimestamp = Int(Date().timeIntervalSince1970)

        for (offset, server) in servers.enumerated() {
            guard let credentials = try? vault.read(for: server.credentialID) else {
                skipped += 1
                unpublishedIDs.insert(server.id)
                continue
            }
            let jumpHostCredentials = server.jumpHost.flatMap { try? vault.read(for: $0.credentialID) }
            guard server.jumpHost == nil || jumpHostCredentials?.isEmpty == false else {
                skipped += 1
                unpublishedIDs.insert(server.id)
                continue
            }

            let portable = server.makePortableConfig(
                savedAtUnix: baseTimestamp + offset,
                credentials: credentials,
                jumpHostCredentials: jumpHostCredentials
            )
            guard let data = try? encoder.encode(portable),
                  let plaintext = String(data: data, encoding: .utf8) else {
                skipped += 1
                unpublishedIDs.insert(server.id)
                continue
            }

            let accepted = await uploadEncryptedConfig(
                token: token,
                masterPassword: masterPassword,
                accountID: accountID,
                plaintextConfig: plaintext,
                vectorClock: ["client": baseTimestamp + offset],
                allowQueueOnNetworkFailure: true
            )
            if accepted {
                published += 1
            } else {
                skipped += 1
                unpublishedIDs.insert(server.id)
            }
        }

        setPendingLocalAssetRecoveryIDs(unpublishedIDs)
        lastSyncMessage = skipped == 0
            ? "已提交 \(published) 项本地资产到云端"
            : "已提交 \(published) 项，\(skipped) 项未能发布，请检查凭据或网络后重试"
    }

    /// Explicit user-triggered reconciliation. It pulls a full inventory first,
    /// publishes only local IDs absent from that inventory, then verifies the
    /// same account's inventory again. Known remote tombstones remain known and
    /// therefore cannot be accidentally revived by this path.
    func reconcileAssetInventory(
        token: String,
        masterPassword: String,
        store: ServerStore,
        accountID: String
    ) async {
        let pulled = await pullAndApplyConfigs(
            token: token,
            masterPassword: masterPassword,
            store: store,
            accountID: accountID,
            forceFullInventory: true
        )
        guard pulled else { return }

        let attemptedIDs = pendingLocalAssetRecoveryIDs
        guard !attemptedIDs.isEmpty else { return }

        await publishPendingLocalAssets(
            token: token,
            masterPassword: masterPassword,
            store: store,
            accountID: accountID
        )

        do {
            let remoteItems = try await network.pullConfigs(token: token)
            let cloudKnownAssetIDs = Set(remoteItems.compactMap { item -> String? in
                guard let rawID = item.asset_id?.lowercased(),
                      UUID(uuidString: rawID) != nil else {
                    return nil
                }
                return rawID
            })
            let attemptedRawIDs = Set(attemptedIDs.map { $0.uuidString.lowercased() })
            let unverifiedRawIDs = SyncPullRecoveryPolicy.unverifiedPublishedAssetIDs(
                attemptedLocalAssetIDs: attemptedRawIDs,
                cloudKnownAssetIDs: cloudKnownAssetIDs
            )
            let unresolvedIDs = Set(unverifiedRawIDs.compactMap(UUID.init(uuidString:)));
            setPendingLocalAssetRecoveryIDs(unresolvedIDs)

            let verified = attemptedIDs.count - unresolvedIDs.count
            lastSyncMessage = unresolvedIDs.isEmpty
                ? "双向同步完成：已验证云端资产 \(verified) 项"
                : "双向同步未完成：已验证 \(verified) 项，\(unresolvedIDs.count) 项待重试"
        } catch {
            // Do not claim that a queued or accepted upload reached the server
            // until a pull from the same authenticated account confirms it.
            setPendingLocalAssetRecoveryIDs(attemptedIDs)
            recordSyncFailure(error)
        }
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
            guard let scope = AccountScope(username: accountID), activeAccountScope == scope else {
                throw NetworkService.NetworkError.decodeFailed
            }
            let encrypted: Data
            if Self.isV2CipherWriteEnabled(scope: scope) {
                try orbitManager.prepareConfigRootKeyV2(masterPassword: masterPassword, accountScope: scope)
                encrypted = try orbitManager.encryptConfigV2(Data(normalizedPlain.utf8))
            } else {
                encrypted = try orbitManager.encrypt(password: masterPassword, data: normalizedPlain)
            }
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
                shadowStore.save(localPortable, accountID: accountID)
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
                        accountID: accountID,
                        localPortable: localPortable,
                        fallbackPayload: payload
                    )
                }
                if allowQueueOnNetworkFailure, NetworkService.isRetriableNetworkError(error) {
                    await SyncQueue.shared.enqueueUpload(
                        payload: payload,
                        accountID: accountID,
                        reason: OperationRecoveryMapper.sync(error).diagnosticCode
                    )
                    lastSyncMessage = "网络波动，已加入后台同步队列"
                    return true
                }
                if let net = error as? NetworkService.NetworkError,
                   case .unauthorized = net {
                    setSyncRecoveryPresentation(OperationRecoveryMapper.syncTokenUnavailable())
                    return false
                }
                throw error
            }
        } catch {
            recordSyncFailure(error)
            return false
        }
    }

    /// Rewrites the complete non-purged V1 cloud snapshot as V2 in one server
    /// transaction. The migration is intentionally explicit: normal sync is
    /// never blocked by a server that has not deployed the migration endpoint.
    /// A stale snapshot is rejected wholesale, leaving every V1 record intact.
    func migrateRemoteConfigCryptoToV2(
        token: String,
        masterPassword: String,
        accountID: String
    ) async throws -> SyncConfigCipherMigrationPolicy.Result {
        guard let scope = AccountScope(username: accountID), activeAccountScope == scope else {
            throw NetworkService.NetworkError.decodeFailed
        }
        let remoteItems = try await completeConfigSnapshot(token: token)
        let decodedRemoteItems: [(item: UploadConfigData, blob: Data)] = try remoteItems.map { item in
            guard let blob = Data(base64Encoded: item.encrypted_blob_base64) else {
                throw NetworkService.NetworkError.decodeFailed
            }
            return (item, blob)
        }
        let legacyItems = decodedRemoteItems.filter { !OrbitManager.isV2ConfigBlob($0.blob) }

        try orbitManager.prepareConfigRootKeyV2(masterPassword: masterPassword, accountScope: scope)
        let v2RootKey = try orbitManager.configRootKeyV2ForBackground(scope: scope)
        // Verify the already-V2 part of the snapshot before touching V1. A
        // broken existing V2 record must fail closed rather than create a
        // mixed snapshot that the caller could mistake for a finished upgrade.
        for remote in decodedRemoteItems where OrbitManager.isV2ConfigBlob(remote.blob) {
            _ = try Self.decryptBlob(password: masterPassword, encrypted: remote.blob, v2RootKey: v2RootKey)
        }
        // A marker can be absent after app reinstall, and a previously stored
        // marker must never be treated as proof without this authenticated
        // full-snapshot verification.
        guard !legacyItems.isEmpty else {
            Self.markV2CipherWriteEnabled(scope: scope)
            return .alreadyVerified(decodedRemoteItems.count)
        }
        var replacements: [ConfigCryptoMigrationItemRequest] = []
        replacements.reserveCapacity(decodedRemoteItems.count)
        for remote in decodedRemoteItems {
            let item = remote.item
            let v2Blob: Data
            if OrbitManager.isV2ConfigBlob(remote.blob) {
                v2Blob = remote.blob
            } else {
                let plaintext = try Self.decryptBlob(password: masterPassword, encrypted: remote.blob)
                v2Blob = try orbitManager.encryptConfigV2(plaintext)
            }
            guard OrbitManager.isV2ConfigBlob(v2Blob) else {
                throw NetworkService.NetworkError.decodeFailed
            }
            let digest = Data(SHA256.hash(data: remote.blob)).base64EncodedString()
            replacements.append(ConfigCryptoMigrationItemRequest(
                id: item.id,
                expected_vector_clock: item.vector_clock,
                expected_blob_sha256: digest,
                encrypted_blob_base64: v2Blob.base64EncodedString(),
                next_vector_clock: Self.bumpClock(item.vector_clock, actor: "crypto_v2")
            ))
        }

        let response = try await network.migrateConfigCryptoV2(items: replacements)
        guard response.migrated_count == replacements.count else {
            throw NetworkService.NetworkError.decodeFailed
        }

        // Verify the committed snapshot with the exact in-memory V2 root before
        // returning success. This never writes local state or enables a new
        // writer mode on partial/failed verification.
        let verified = try await completeConfigSnapshot(token: token)
        let expectedIDs = Set(replacements.map(\.id))
        let verifiedIDs = Set(verified.map(\.id))
        guard expectedIDs.isSubset(of: verifiedIDs) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        guard verified.allSatisfy({ item in
            guard let blob = Data(base64Encoded: item.encrypted_blob_base64),
                  OrbitManager.isV2ConfigBlob(blob) else { return false }
            return (try? Self.decryptBlob(password: masterPassword, encrypted: blob, v2RootKey: v2RootKey)) != nil
        }) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        Self.markV2CipherWriteEnabled(scope: scope)
        return .migrated(legacyItems.count)
    }

    private func completeConfigSnapshot(token: String) async throws -> [UploadConfigData] {
        var items = try await network.pullConfigs(token: token)
        var offset = 0
        while true {
            let page = try await network.pullTrash(limit: 500, offset: offset)
            items.append(contentsOf: page.items)
            offset += page.items.count
            if page.items.isEmpty || offset >= page.total { break }
        }
        var ids = Set<UInt>()
        guard items.allSatisfy({ ids.insert($0.id).inserted }) else {
            throw NetworkService.NetworkError.decodeFailed
        }
        return items
    }

}

extension SyncService: AccountScopedPresentationService {}

@MainActor
extension PortForwardProfileStore {
    func synchronize(token: String, masterPassword: String, accountID: String, network: NetworkService, orbitManager: OrbitManager) async throws {
        guard let scope = AccountScope(username: accountID) else { throw StoreError.accountMismatch }
        let items = try await network.pullConfigs(token: token)
        var latest: (PortForwardProfileSyncEnvelope, UInt, String)?
        for item in items where (item.state ?? "active") == "active" {
            guard let encrypted = Data(base64Encoded: item.encrypted_blob_base64),
                  let plain = try? decryptPortProfile(encrypted, password: masterPassword, scope: scope, orbitManager: orbitManager),
                  let envelope = PortForwardProfileSyncContract.decode(plain) else { continue }
            if latest == nil || envelope.updatedAtUnix > latest!.0.updatedAtUnix { latest = (envelope, item.id, item.vector_clock) }
        }
        if let latest { merge(latest.0, scope: scope) }
        let envelope = makeEnvelope(scope: scope)
        let plain = try PortForwardProfileSyncContract.encode(envelope)
        let fingerprint = SHA256.hash(data: plain).map { String(format: "%02x", $0) }.joined()
        let metadata = syncMetadata()
        let remoteID = latest?.1 ?? metadata.remoteID
        let remoteClock = latest?.2 ?? metadata.vectorClock
        if remoteID != nil && fingerprint == metadata.payloadFingerprint {
            return
        }
        let encrypted: Data
        if SyncService.isV2CipherWriteEnabled(scope: scope) {
            try orbitManager.prepareConfigRootKeyV2(masterPassword: masterPassword, accountScope: scope)
            encrypted = try orbitManager.encryptConfigV2(plain)
        } else {
            guard let text = String(data: plain, encoding: .utf8) else { throw StoreError.invalidEnvelope }
            encrypted = try orbitManager.encrypt(password: masterPassword, data: text)
        }
        let response = try await network.uploadConfig(token: token, payload: UploadConfigRequest(
            id: remoteID,
            encrypted_blob_base64: encrypted.base64EncodedString(),
            vector_clock: bump(remoteClock)))
        try recordRemoteMetadata(id: response.id, vectorClock: response.vector_clock, payloadFingerprint: fingerprint)
    }

    private func decryptPortProfile(_ encrypted: Data, password: String, scope: AccountScope, orbitManager: OrbitManager) throws -> Data {
        if OrbitManager.isV2ConfigBlob(encrypted) {
            try orbitManager.prepareConfigRootKeyV2(masterPassword: password, accountScope: scope)
            return try orbitManager.decryptConfigV2(encrypted)
        }
        return try orbitManager.decrypt(password: password, encrypted: encrypted)
    }
}

@MainActor
extension SshKeySyncStore {
    func synchronize(token: String, masterPassword: String, accountID: String,
                     network: NetworkService, orbitManager: OrbitManager,
                     serverStore: ServerStore, credentialVault: CredentialVault = .shared) async throws {
        guard let scope = AccountScope(username: accountID) else { throw StoreError.accountMismatch }
        let items = try await network.pullConfigs(token: token)
        var latest: (SshKeySyncEnvelope, UInt, String)?
        for item in items where (item.state ?? "active") == "active" {
            guard let encrypted = Data(base64Encoded: item.encrypted_blob_base64),
                  let plain = try? decryptKeyEnvelope(encrypted, password: masterPassword, scope: scope, orbitManager: orbitManager),
                  let envelope = SshKeySyncContract.decode(plain) else { continue }
            if latest == nil || envelope.updatedAtUnix > latest!.0.updatedAtUnix { latest = (envelope, item.id, item.vector_clock) }
        }
        if let latest { try merge(latest.0) }

        // Restore explicit key-to-asset assignments only inside the active
        // account. Existing passwords are preserved as optional fallback.
        for key in keys {
            for rawID in key.assignedAssetIds {
                guard let id = UUID(uuidString: rawID),
                      let server = serverStore.servers.first(where: { $0.id == id }) else { continue }
                var credentials = try credentialVault.read(for: server.credentialID) ?? .init()
                if credentials.privateKeyContent == key.privateKey && credentials.privateKeyPassphrase == key.passphrase { continue }
                credentials.privateKeyContent = key.privateKey
                credentials.privateKeyPassphrase = key.passphrase
                var updated = server; updated.authMethod = .key
                _ = serverStore.addOrUpdate(updated, credentials: credentials)
            }
        }

        let envelope = makeEnvelope()
        guard !envelope.keys.isEmpty || !envelope.tombstones.isEmpty || latest != nil else { return }
        let plain = try SshKeySyncContract.encode(envelope)
        let fingerprint = SHA256.hash(data: plain).map { String(format: "%02x", $0) }.joined()
        let localMetadata = metadata()
        let remoteID = latest?.1 ?? localMetadata.0
        let clock = latest?.2 ?? localMetadata.1
        if fingerprint == localMetadata.2, remoteID != nil { return }

        let encrypted: Data
        if SyncService.isV2CipherWriteEnabled(scope: scope) {
            try orbitManager.prepareConfigRootKeyV2(masterPassword: masterPassword, accountScope: scope)
            encrypted = try orbitManager.encryptConfigV2(plain)
        } else {
            guard let text = String(data: plain, encoding: .utf8) else { throw StoreError.accountMismatch }
            encrypted = try orbitManager.encrypt(password: masterPassword, data: text)
        }
        let response = try await network.uploadConfig(token: token, payload: UploadConfigRequest(
            id: remoteID, encrypted_blob_base64: encrypted.base64EncodedString(),
            vector_clock: bumpKeyClock(clock)))
        try recordRemote(id: response.id, clock: response.vector_clock, fingerprint: fingerprint)
    }

    private func decryptKeyEnvelope(_ encrypted: Data, password: String, scope: AccountScope, orbitManager: OrbitManager) throws -> Data {
        if OrbitManager.isV2ConfigBlob(encrypted) {
            try orbitManager.prepareConfigRootKeyV2(masterPassword: password, accountScope: scope)
            return try orbitManager.decryptConfigV2(encrypted)
        }
        return try orbitManager.decrypt(password: password, encrypted: encrypted)
    }

    private func bumpKeyClock(_ raw: String) -> String {
        var clock = ((try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Int]) ?? [:]
        clock["ssh_key_client", default: 0] += 1
        return String(data: (try? JSONSerialization.data(withJSONObject: clock, options: [.sortedKeys])) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }
}
