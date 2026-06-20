import Foundation
import CryptoKit

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

struct ConflictDecision {
    let choice: ConflictChoice
}

struct SyncShadowSnapshot: Codable, Equatable {
    let id: String
    let name: String
    let group: String
    let host: String
    let port: Int
    let username: String
    let authMethod: String
    let transport: String
    let networkDeviceProfile: String
    let allowPasswordFallback: Bool
    let passwordDigest: String
    let privateKeyDigest: String
    let privateKeyPassphraseDigest: String

    init(_ portable: PortableServerConfig, authenticationKey: Data) {
        let key = SymmetricKey(data: authenticationKey)
        id = portable.id
        name = portable.name
        group = portable.group
        host = portable.host
        port = portable.port
        username = portable.username
        authMethod = portable.authMethod
        transport = portable.transport
        networkDeviceProfile = portable.networkDeviceProfile
        allowPasswordFallback = portable.allowPasswordFallback
        passwordDigest = Self.digest(portable.password, key: key)
        privateKeyDigest = Self.digest(portable.privateKeyContent, key: key)
        privateKeyPassphraseDigest = Self.digest(portable.privateKeyPassphrase, key: key)
    }

    private static func digest(_ value: String, key: SymmetricKey) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

final class SyncShadowStore {
    private let key = "orbitterm.sync.shadow.v3"
    private let legacyKeys = ["orbitterm.sync.shadow.v2"]
    private let keychainService = "com.orbitterm.sync.shadow"
    private let keychainAccount = "hmac-key-v1"
    let authenticationKey: Data

    init() {
        // v2 曾保存完整 PortableServerConfig，其中包含明文凭据。升级后立即清除。
        for legacyKey in legacyKeys {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
        if let stored = try? KeychainDataStore.read(service: keychainService, account: keychainAccount),
           stored.count >= 32 {
            authenticationKey = stored
        } else {
            let generated = (try? SecurityPrimitives.randomBytes(count: 32)) ?? Data(UUID().uuidString.utf8)
            authenticationKey = generated
            try? KeychainDataStore.save(generated, service: keychainService, account: keychainAccount)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func read(id: String) -> SyncShadowSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: SyncShadowSnapshot].self, from: data) else {
            return nil
        }
        return map[id]
    }

    func save(_ portable: PortableServerConfig) {
        var map = readAll()
        map[portable.id] = snapshot(for: portable)
        persist(map)
    }

    func readAll() -> [String: SyncShadowSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: SyncShadowSnapshot].self, from: data) else {
            return [:]
        }
        return map
    }

    func saveMany(_ portables: [PortableServerConfig]) {
        guard !portables.isEmpty else { return }
        var map = readAll()
        for portable in portables {
            map[portable.id] = snapshot(for: portable)
        }
        persist(map)
    }

    private func persist(_ map: [String: SyncShadowSnapshot]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func snapshot(for portable: PortableServerConfig) -> SyncShadowSnapshot {
        SyncShadowSnapshot(portable, authenticationKey: authenticationKey)
    }
}

struct SyncPreparedItem {
    let server: ServerEntry
    let portable: PortableServerConfig
    let remote: UploadConfigData
}

struct SyncDecodedRemoteItem {
    let remoteID: UInt
    let server: ServerEntry
    let portable: PortableServerConfig
    let credentials: ServerCredentials
    let remote: UploadConfigData
}

struct SyncPullPreparation {
    let items: [SyncPreparedItem]
    let tombstonedRemotes: [(assetID: UUID, remote: UploadConfigData)]
    let skipped: Int
    let tombstoneSkipped: Int
    let duplicateSkipped: Int
    let credentialWriteCount: Int
    let remoteConfigIDsToDelete: [UInt]
}
