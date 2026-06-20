import Foundation

enum AddServerSilentSync {
    static func uploadStatusMessage(
        server: ServerEntry,
        credentials: ServerCredentials,
        token: String?,
        masterPassword: String?,
        accountID: String,
        syncService: SyncService,
        now: Date = Date()
    ) async -> String? {
        guard let token, let masterPassword else {
            return "已本地保存，登录后将自动同步"
        }

        let timestamp = Int(now.timeIntervalSince1970)
        let portable = server.makePortableConfig(savedAtUnix: timestamp, credentials: credentials)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        guard let jsonData = try? encoder.encode(portable),
              let plaintext = String(data: jsonData, encoding: .utf8) else {
            return "同步暂不可用，已本地保存"
        }

        let ok = await syncService.uploadEncryptedConfig(
            token: token,
            masterPassword: masterPassword,
            accountID: accountID,
            plaintextConfig: plaintext,
            vectorClock: ["client": timestamp],
            allowQueueOnNetworkFailure: true
        )

        return ok ? nil : "云端同步失败，稍后自动重试"
    }
}
