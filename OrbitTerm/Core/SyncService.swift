import Foundation

@MainActor
final class SyncService: ObservableObject {
    static let shared = SyncService()

    @Published var lastSyncMessage: String = "尚未同步"
    @Published var pendingConflictPrompt: SyncConflictPrompt?

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

}
