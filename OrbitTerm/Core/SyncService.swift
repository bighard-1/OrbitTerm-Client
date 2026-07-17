import CryptoKit
import Foundation

@MainActor
final class SyncService: ObservableObject {
    static let shared = SyncService()

    @Published var lastSyncMessage: String = "尚未同步"
    /// Counts and a non-reversible account marker for support diagnosis. Never
    /// includes asset names, UUIDs, credentials, or the access token itself.
    @Published private(set) var lastInventoryDiagnostic: String = ""
    @Published var pendingConflictPrompt: SyncConflictPrompt?
    @Published private(set) var pendingLocalAssetRecoveryIDs: Set<UUID> = []

    var pendingLocalAssetRecoveryCount: Int {
        pendingLocalAssetRecoveryIDs.count
    }

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

    func chooseConflict(_ choice: ConflictChoice) {
        conflictContinuation?.resume(returning: ConflictDecision(choice: choice))
        conflictContinuation = nil
        pendingConflictPrompt = nil
    }

    func setPendingLocalAssetRecoveryIDs(_ ids: Set<UUID>) {
        pendingLocalAssetRecoveryIDs = ids
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
            lastInventoryDiagnostic = "同步诊断读取失败：\(error.localizedDescription)"
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

            let portable = server.makePortableConfig(
                savedAtUnix: baseTimestamp + offset,
                credentials: credentials
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
            lastSyncMessage = "已提交本地资产，但云端复查失败：\(error.localizedDescription)"
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
                    await SyncQueue.shared.enqueueUpload(payload: payload, accountID: accountID, reason: error.localizedDescription)
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

}
