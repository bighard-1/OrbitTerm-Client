import Foundation

@MainActor
final class SyncService: ObservableObject {
    @Published var lastSyncMessage: String = "尚未同步"

    private let network: NetworkService
    private let orbitManager: OrbitManager

    init(network: NetworkService = .shared, orbitManager: OrbitManager? = nil) {
        self.network = network
        self.orbitManager = orbitManager ?? OrbitManager()
    }

    // 将本地明文配置先交给 Rust 核心加密，再上传密文到后端 /upload。
    func uploadEncryptedConfig(
        token: String,
        masterPassword: String,
        plaintextConfig: String,
        vectorClock: [String: Int],
        configID: UInt? = nil
    ) async -> Bool {
        do {
            let encrypted = try orbitManager.encrypt(password: masterPassword, data: plaintextConfig)
            let vectorClockData = try JSONSerialization.data(withJSONObject: vectorClock)
            guard let vectorClockString = String(data: vectorClockData, encoding: .utf8) else {
                lastSyncMessage = "同步失败: 版本号编码失败"
                return false
            }

            let payload = UploadConfigRequest(
                id: configID,
                encrypted_blob_base64: encrypted.base64EncodedString(),
                vector_clock: vectorClockString
            )

            let response = try await network.uploadConfig(token: token, payload: payload)
            lastSyncMessage = "同步成功，配置ID: \(response.id)"
            return true
        } catch {
            lastSyncMessage = "同步失败: \(error.localizedDescription)"
            return false
        }
    }
}
