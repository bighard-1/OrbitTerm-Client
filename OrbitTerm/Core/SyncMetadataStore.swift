import CryptoKit
import Foundation

struct AssetSyncMetadata: Codable, Equatable {
    var remoteID: UInt?
    var vectorClock: String
    var state: String
    var serverRevision: UInt64
}

private struct AccountSyncMetadata: Codable {
    var cursor: UInt64 = 0
    var assets: [String: AssetSyncMetadata] = [:]
}

/// 保存非敏感同步水位。按账号隔离，避免切换账号时复用错误游标而漏拉资产。
final class SyncMetadataStore {
    static let shared = SyncMetadataStore()

    private let defaults = UserDefaults.standard
    private let keychain = KeychainManager.shared
    private let lock = NSLock()
    private let keyPrefix = "orbitterm.sync.metadata.v1."
    private let keychainService = "com.orbitterm.sync"
    private let deviceAccount = "device_id_v1"

    private init() {}

    var deviceID: UUID {
        lock.lock()
        defer { lock.unlock() }
        if let raw = (try? keychain.readString(service: keychainService, account: deviceAccount)) ?? nil,
           let existing = UUID(uuidString: raw) {
            return existing
        }
        let generated = UUID()
        try? keychain.saveString(generated.uuidString, service: keychainService, account: deviceAccount)
        return generated
    }

    func cursor(accountID: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return readUnlocked(accountID: accountID).cursor
    }

    func saveCursor(_ cursor: UInt64, accountID: String) {
        lock.lock()
        defer { lock.unlock() }
        var metadata = readUnlocked(accountID: accountID)
        metadata.cursor = max(metadata.cursor, cursor)
        persistUnlocked(metadata, accountID: accountID)
    }

    func resetCursor(accountID: String) {
        lock.lock()
        defer { lock.unlock() }
        var metadata = readUnlocked(accountID: accountID)
        metadata.cursor = 0
        persistUnlocked(metadata, accountID: accountID)
    }

    func asset(_ assetID: UUID, accountID: String) -> AssetSyncMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return readUnlocked(accountID: accountID).assets[assetID.uuidString]
    }

    func saveAsset(_ item: UploadConfigData, fallbackAssetID: UUID? = nil, accountID: String) {
        guard let assetID = item.asset_id.flatMap(UUID.init(uuidString:)) ?? fallbackAssetID else { return }
        lock.lock()
        defer { lock.unlock() }
        var metadata = readUnlocked(accountID: accountID)
        metadata.assets[assetID.uuidString] = AssetSyncMetadata(
            remoteID: item.id,
            vectorClock: item.vector_clock,
            state: item.state ?? "active",
            serverRevision: item.server_revision ?? 0
        )
        persistUnlocked(metadata, accountID: accountID)
    }

    func removeAsset(_ assetID: UUID, accountID: String) {
        lock.lock()
        defer { lock.unlock() }
        var metadata = readUnlocked(accountID: accountID)
        metadata.assets.removeValue(forKey: assetID.uuidString)
        persistUnlocked(metadata, accountID: accountID)
    }

    func nextVectorClock(assetID: UUID, accountID: String) -> String {
        let current = asset(assetID, accountID: accountID)?.vectorClock ?? "{}"
        return incrementVectorClock(current)
    }

    func incrementVectorClock(_ current: String) -> String {
        var clock = (try? JSONDecoder().decode([String: Int64].self, from: Data(current.utf8))) ?? [:]
        let key = deviceID.uuidString.lowercased()
        let monotonicWallClock = Int64(Date().timeIntervalSince1970 * 1_000)
        clock[key] = max((clock[key] ?? 0) + 1, monotonicWallClock)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(clock), let encoded = String(data: data, encoding: .utf8) else {
            return "{\"\(key)\":1}"
        }
        return encoded
    }

    private func readUnlocked(accountID: String) -> AccountSyncMetadata {
        guard let data = defaults.data(forKey: storageKey(accountID)),
              let decoded = try? JSONDecoder().decode(AccountSyncMetadata.self, from: data) else {
            return AccountSyncMetadata()
        }
        return decoded
    }

    private func persistUnlocked(_ metadata: AccountSyncMetadata, accountID: String) {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        defaults.set(data, forKey: storageKey(accountID))
    }

    private func storageKey(_ accountID: String) -> String {
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return keyPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum SyncClientInfo {
    static var platform: String {
#if os(iOS)
        return "ios"
#elseif os(macOS)
        return "macos"
#else
        return "apple"
#endif
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}
