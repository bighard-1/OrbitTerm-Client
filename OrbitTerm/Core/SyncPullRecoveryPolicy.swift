import Foundation
import CryptoKit
import Combine

/// Decides when a device with no local asset cache needs an inventory pull.
/// Incremental sync is authoritative for deltas, but an empty delta cannot
/// reconstruct an empty cache when the server has pre-existing legacy assets.
enum SyncPullRecoveryPolicy {
    static func shouldPerformFullPull(
        localAssetCount: Int,
        incrementalResponseHadChanges: Bool
    ) -> Bool {
        localAssetCount == 0 && !incrementalResponseHadChanges
    }

    /// A confirmed empty inventory must never silently overwrite local assets.
    /// Instead, an explicit user action may publish the local inventory.
    static func localAssetIDsPendingExplicitPublication(
        localAssetIDs: Set<String>,
        cloudKnownAssetIDs: Set<String>
    ) -> Set<String> {
        localAssetIDs.subtracting(cloudKnownAssetIDs)
    }

    /// A manual reconciliation may only claim success after the same account's
    /// follow-up inventory contains the local asset IDs it attempted to publish.
    /// The function deliberately works on IDs only: it never inspects names,
    /// credentials, or user-visible status text.
    static func unverifiedPublishedAssetIDs(
        attemptedLocalAssetIDs: Set<String>,
        cloudKnownAssetIDs: Set<String>
    ) -> Set<String> {
        attemptedLocalAssetIDs.subtracting(cloudKnownAssetIDs)
    }

    static func remoteAssetsRequireMasterPasswordRecovery(
        remoteAssetCount: Int,
        decodedRemoteAssetCount: Int
    ) -> Bool {
        remoteAssetCount > 0 && decodedRemoteAssetCount == 0
    }

    /// A record converted into a remote tombstone must remain available to
    /// other devices; only unrelated duplicate records may be purged.
    static func remoteRecordIDsSafeToPurge(
        candidateRecordIDs: Set<UInt>,
        migratedTombstoneRecordIDs: Set<UInt>
    ) -> [UInt] {
        Array(candidateRecordIDs.subtracting(migratedTombstoneRecordIDs)).sorted()
    }

    /// Reconciles the server's active inventory with its trash feed by asset
    /// identity. A soft delete can be represented by a different config-record
    /// ID than the last active version, so record-ID deduplication can leave
    /// both versions in the same pull and accidentally resurrect the asset.
    /// Trash is authoritative for the matching asset during this pull.
    static func mergeRemoteInventory<Item>(
        activeItems: [Item],
        trashItems: [Item],
        assetID: (Item) -> String?,
        recordID: (Item) -> String
    ) -> [Item] {
        var itemsByAssetIdentity: [String: Item] = [:]
        for item in activeItems {
            itemsByAssetIdentity[remoteAssetIdentity(
                assetID: assetID(item),
                recordID: recordID(item)
            )] = item
        }
        for item in trashItems {
            itemsByAssetIdentity[remoteAssetIdentity(
                assetID: assetID(item),
                recordID: recordID(item)
            )] = item
        }
        return itemsByAssetIdentity.values.sorted { lhs, rhs in
            remoteAssetIdentity(assetID: assetID(lhs), recordID: recordID(lhs))
                < remoteAssetIdentity(assetID: assetID(rhs), recordID: recordID(rhs))
        }
    }

    private static func remoteAssetIdentity(assetID: String?, recordID: String) -> String {
        if let rawAssetID = assetID?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
           !rawAssetID.isEmpty {
            return "asset:\(rawAssetID.lowercased())"
        }
        // Malformed legacy records are kept distinct rather than allowing one
        // record to hide another without a stable asset identity.
        return "record:\(recordID)"
    }
}

struct SshKeySyncEnvelope: Codable, Equatable {
    let kind: String
    let version: Int
    let updatedAtUnix: Int64
    let keys: [SshKeySyncWire]
    let tombstones: [SshKeyTombstoneWire]
}

struct SshKeySyncWire: Codable, Equatable {
    let id: String
    let name: String
    let format: String
    let materialFingerprint: String
    let createdAtUnix: Int64
    let updatedAtUnix: Int64
    let assignedAssetIds: [String]
    let privateKey: String
    let passphrase: String
}

struct SshKeyTombstoneWire: Codable, Equatable {
    let id: String
    let deletedAtUnix: Int64
}

/// Wire-compatible reader for the Windows `orbit_ssh_keys` v1 encrypted
/// envelope. Validation happens before any private material may enter Keychain.
enum SshKeySyncContract {
    static let marker = "orbit_ssh_keys"
    static let version = 1
    static let maximumKeys = 128
    private static let maximumPrivateKeyBytes = 1_024 * 1_024
    private static let maximumPassphraseBytes = 16 * 1_024

    static func decode(_ data: Data) -> SshKeySyncEnvelope? {
        guard let envelope = try? JSONDecoder().decode(SshKeySyncEnvelope.self, from: data) else { return nil }
        return try? validate(envelope)
    }

    static func encode(_ envelope: SshKeySyncEnvelope) throws -> Data {
        try JSONEncoder().encode(validate(envelope))
    }

    static func validate(_ envelope: SshKeySyncEnvelope) throws -> SshKeySyncEnvelope {
        guard envelope.kind == marker,
              envelope.version == version,
              envelope.updatedAtUnix > 0,
              envelope.keys.count <= maximumKeys,
              envelope.tombstones.count <= maximumKeys * 4 else {
            throw ContractError.invalidEnvelope
        }

        let keys = try envelope.keys.map(normalize)
        let tombstones = try envelope.tombstones.map { item in
            guard item.deletedAtUnix > 0 else { throw ContractError.invalidEnvelope }
            return SshKeyTombstoneWire(id: try canonicalUUID(item.id), deletedAtUnix: item.deletedAtUnix)
        }
        guard Set(keys.map(\.id)).count == keys.count,
              Set(keys.map(\.materialFingerprint)).count == keys.count,
              Set(tombstones.map(\.id)).count == tombstones.count else {
            throw ContractError.invalidEnvelope
        }
        return SshKeySyncEnvelope(
            kind: marker,
            version: version,
            updatedAtUnix: envelope.updatedAtUnix,
            keys: keys,
            tombstones: tombstones
        )
    }

    private static func normalize(_ item: SshKeySyncWire) throws -> SshKeySyncWire {
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined()
        let privateKey = try normalizePrivateKey(item.privateKey)
        guard !name.isEmpty,
              name.count <= 80,
              item.createdAtUnix > 0,
              item.updatedAtUnix >= item.createdAtUnix,
              item.assignedAssetIds.count <= 512,
              item.passphrase.utf8.count <= maximumPassphraseBytes,
              materialFingerprint(privateKey) == item.materialFingerprint else {
            throw ContractError.invalidKey
        }
        return SshKeySyncWire(
            id: try canonicalUUID(item.id),
            name: name,
            format: item.format,
            materialFingerprint: item.materialFingerprint,
            createdAtUnix: item.createdAtUnix,
            updatedAtUnix: item.updatedAtUnix,
            assignedAssetIds: try Array(Set(item.assignedAssetIds.map(canonicalUUID))).sorted(),
            privateKey: privateKey,
            passphrase: item.passphrase
        )
    }

    static func normalizePrivateKey(_ raw: String) throws -> String {
        let value = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let supported = value.hasPrefix("PuTTY-User-Key-File-2:") ||
            value.hasPrefix("PuTTY-User-Key-File-3:") ||
            value.contains("-----BEGIN OPENSSH PRIVATE KEY-----") ||
            value.contains("-----BEGIN RSA PRIVATE KEY-----") ||
            value.contains("-----BEGIN EC PRIVATE KEY-----") ||
            value.contains("-----BEGIN PRIVATE KEY-----") ||
            value.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----")
        guard !value.isEmpty,
              !value.contains("\0"),
              value.utf8.count <= maximumPrivateKeyBytes,
              supported else { throw ContractError.invalidKey }
        return value + "\n"
    }

    static func materialFingerprint(_ privateKey: String) -> String {
        let digest = Data(SHA256.hash(data: Data(privateKey.utf8))).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(digest)"
    }

    private static func canonicalUUID(_ raw: String) throws -> String {
        guard let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ContractError.invalidIdentity
        }
        return id.uuidString.lowercased()
    }

    private enum ContractError: Error {
        case invalidEnvelope
        case invalidIdentity
        case invalidKey
    }
}

enum SshKeyMergePolicy {
    static func merge(
        local: [SshKeySyncWire],
        localOnly: [SshKeySyncWire],
        tombstones: [String: Int64],
        remote: SshKeySyncEnvelope
    ) -> (keys: [SshKeySyncWire], tombstones: [String: Int64]) {
        var resolvedTombstones = tombstones
        for tombstone in remote.tombstones {
            resolvedTombstones[tombstone.id] = max(resolvedTombstones[tombstone.id] ?? 0, tombstone.deletedAtUnix)
        }
        var merged = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let localOnlyIDs = Set(localOnly.map(\.id))
        let localOnlyFingerprints = Set(localOnly.map(\.materialFingerprint))
        for key in remote.keys.sorted(by: { $0.updatedAtUnix < $1.updatedAtUnix }) {
            guard !localOnlyIDs.contains(key.id),
                  !localOnlyFingerprints.contains(key.materialFingerprint),
                  resolvedTombstones[key.id, default: 0] < key.updatedAtUnix else { continue }
            if let localKey = merged[key.id], localKey.updatedAtUnix > key.updatedAtUnix { continue }
            if merged.values.contains(where: { $0.id != key.id && $0.materialFingerprint == key.materialFingerprint }) { continue }
            merged[key.id] = key
        }
        merged = merged.filter { resolvedTombstones[$0.key, default: 0] < $0.value.updatedAtUnix }
        return (merged.values.sorted { $0.id < $1.id }, resolvedTombstones)
    }
}

private struct SshKeyVaultDocument: Codable {
    var version = 1
    var keys: [SshKeySyncWire] = []
    var localOnlyKeys: [SshKeySyncWire] = []
    var tombstones: [String: Int64] = [:]
    var remoteConfigID: UInt?
    var vectorClock = "{}"
    var payloadFingerprint = ""
}

/// Account-isolated Keychain library for reusable SSH keys. Private material
/// is decoded only after the E2EE envelope has authenticated successfully.
@MainActor
final class SshKeySyncStore: ObservableObject {
    static let shared = SshKeySyncStore()
    @Published private(set) var keys: [SshKeySyncWire] = []
    private let service = "com.orbitterm.ssh-key-library.v1"
    private var activeScope: AccountScope?
    private var document = SshKeyVaultDocument()

    func activate(username: String) throws {
        guard let scope = AccountScope(username: username) else { return }
        activeScope = scope
        let data = try KeychainDataStore.read(service: service, account: scope.storageIdentifier)
        document = try data.map { try JSONDecoder().decode(SshKeyVaultDocument.self, from: $0) } ?? .init()
        keys = document.keys + document.localOnlyKeys
    }

    func deactivate() { activeScope = nil; document = .init(); keys = [] }

    func deleteActiveAccountData() throws {
        guard let scope = activeScope else { throw StoreError.accountLocked }
        try KeychainDataStore.delete(service: service, account: scope.storageIdentifier)
        document = .init(); keys = []
    }

    func delete(_ rawID: String) throws {
        guard activeScope != nil else { throw StoreError.accountLocked }
        guard let key = document.keys.first(where: { $0.id == rawID }) else { return }
        document.keys.removeAll { $0.id == rawID }
        document.tombstones[rawID] = max(document.tombstones[rawID] ?? 0,
            max(Int64(Date().timeIntervalSince1970), key.updatedAtUnix + 1))
        try persist()
    }

    func recordAssignment(keyID: String, assetID: UUID) throws {
        guard activeScope != nil else { throw StoreError.accountLocked }
        guard let index = document.keys.firstIndex(where: { $0.id == keyID }) else { return }
        let key = document.keys[index]
        let assigned = Array(Set(key.assignedAssetIds + [assetID.uuidString.lowercased()])).sorted()
        document.keys[index] = SshKeySyncWire(id: key.id, name: key.name, format: key.format,
            materialFingerprint: key.materialFingerprint, createdAtUnix: key.createdAtUnix,
            updatedAtUnix: Int64(Date().timeIntervalSince1970), assignedAssetIds: assigned,
            privateKey: key.privateKey, passphrase: key.passphrase)
        try persist()
    }

    func rename(keyID: String, name rawName: String) throws {
        guard activeScope != nil else { throw StoreError.accountLocked }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(80).map(String.init).joined()
        guard !name.isEmpty else { throw StoreError.invalidEnvelope }
        let now = Int64(Date().timeIntervalSince1970)
        if let index = document.keys.firstIndex(where: { $0.id == keyID }) {
            let key = document.keys[index]
            document.keys[index] = SshKeySyncWire(
                id: key.id, name: name, format: key.format,
                materialFingerprint: key.materialFingerprint, createdAtUnix: key.createdAtUnix,
                updatedAtUnix: max(now, key.updatedAtUnix + 1), assignedAssetIds: key.assignedAssetIds,
                privateKey: key.privateKey, passphrase: key.passphrase
            )
        } else if let index = document.localOnlyKeys.firstIndex(where: { $0.id == keyID }) {
            let key = document.localOnlyKeys[index]
            document.localOnlyKeys[index] = SshKeySyncWire(
                id: key.id, name: name, format: key.format,
                materialFingerprint: key.materialFingerprint, createdAtUnix: key.createdAtUnix,
                updatedAtUnix: max(now, key.updatedAtUnix + 1), assignedAssetIds: key.assignedAssetIds,
                privateKey: key.privateKey, passphrase: key.passphrase
            )
        } else {
            return
        }
        try persist()
    }

    func upsert(_ key: SshKeySyncWire) throws {
        guard activeScope != nil else { throw StoreError.accountLocked }
        let normalized = try SshKeySyncContract.validate(.init(
            kind: SshKeySyncContract.marker,
            version: SshKeySyncContract.version,
            updatedAtUnix: max(Int64(Date().timeIntervalSince1970), key.updatedAtUnix),
            keys: [key],
            tombstones: []
        )).keys[0]
        document.tombstones.removeValue(forKey: normalized.id)
        if let index = document.keys.firstIndex(where: { $0.id == normalized.id }) {
            document.keys[index] = normalized
        } else if !document.keys.contains(where: { $0.materialFingerprint == normalized.materialFingerprint }) {
            document.keys.append(normalized)
        }
        try persist()
    }

    @discardableResult
    func upsertPrivateKey(name: String, privateKey rawPrivateKey: String, passphrase: String, assetIDs: [UUID]) throws -> SshKeySyncWire {
        guard activeScope != nil else { throw StoreError.accountLocked }
        let privateKey = try SshKeySyncContract.normalizePrivateKey(rawPrivateKey)
        let fingerprint = SshKeySyncContract.materialFingerprint(privateKey)
        let now = Int64(Date().timeIntervalSince1970)
        let previous = document.keys.first { $0.materialFingerprint == fingerprint }
        let assigned = Array(Set((previous?.assignedAssetIds ?? []) + assetIDs.map { $0.uuidString.lowercased() })).sorted()
        let format: String
        if privateKey.hasPrefix("PuTTY-User-Key-File-") { format = "PuTTY" }
        else if privateKey.contains("BEGIN OPENSSH PRIVATE KEY") { format = "OpenSSH" }
        else if privateKey.contains("BEGIN RSA PRIVATE KEY") { format = "PEM RSA" }
        else if privateKey.contains("BEGIN EC PRIVATE KEY") { format = "PEM EC" }
        else { format = "PKCS#8" }
        let key = SshKeySyncWire(
            id: previous?.id ?? UUID().uuidString.lowercased(),
            name: name,
            format: format,
            materialFingerprint: fingerprint,
            createdAtUnix: previous?.createdAtUnix ?? now,
            updatedAtUnix: max(now, (previous?.updatedAtUnix ?? 0) + 1),
            assignedAssetIds: assigned,
            privateKey: privateKey,
            passphrase: passphrase
        )
        try upsert(key)
        return key
    }

    func merge(_ remote: SshKeySyncEnvelope) throws {
        guard activeScope != nil else { throw StoreError.accountLocked }
        let result = SshKeyMergePolicy.merge(
            local: document.keys,
            localOnly: document.localOnlyKeys,
            tombstones: document.tombstones,
            remote: remote
        )
        document.keys = result.keys
        document.tombstones = result.tombstones
        try persist()
    }

    func makeEnvelope() -> SshKeySyncEnvelope {
        let tombstones = document.tombstones.map { SshKeyTombstoneWire(id: $0.key, deletedAtUnix: $0.value) }.sorted { $0.id < $1.id }
        let updated = max(Int64(Date().timeIntervalSince1970), max(document.keys.map(\.updatedAtUnix).max() ?? 0, tombstones.map(\.deletedAtUnix).max() ?? 0))
        return .init(kind: SshKeySyncContract.marker, version: 1, updatedAtUnix: updated,
            keys: document.keys.sorted { $0.id < $1.id }, tombstones: tombstones)
    }

    func metadata() -> (UInt?, String, String) { (document.remoteConfigID, document.vectorClock, document.payloadFingerprint) }
    func recordRemote(id: UInt, clock: String, fingerprint: String) throws {
        document.remoteConfigID = id; document.vectorClock = clock; document.payloadFingerprint = fingerprint; try persist()
    }

    private func persist() throws {
        guard let scope = activeScope else { throw StoreError.accountLocked }
        try KeychainDataStore.save(try JSONEncoder().encode(document), service: service, account: scope.storageIdentifier)
        keys = document.keys + document.localOnlyKeys
    }

    enum StoreError: Error { case accountLocked, accountMismatch, assignmentFailed, invalidEnvelope }
}

struct PortForwardProfileSyncEnvelope: Codable, Equatable {
    let kind: String
    let version: Int
    let updatedAtUnix: Int64
    let profiles: [PortForwardProfileWire]
    let tombstones: [PortForwardProfileTombstoneWire]
}

struct PortForwardProfileWire: Codable, Equatable {
    let id: String
    let assetId: String
    let name: String
    let mode: String
    let bindHost: String
    let bindPort: Int
    let destinationHost: String
    let destinationPort: Int
    let createdAtUnix: Int64
    let updatedAtUnix: Int64
}

struct PortForwardProfileTombstoneWire: Codable, Equatable {
    let id: String
    let deletedAtUnix: Int64
}

/// Saved-profile-only contract. Runtime tunnel IDs, processes, running state
/// and automatic start preferences are deliberately not cross-device data.
enum PortForwardProfileSyncContract {
    static let marker = "orbit_port_forwards"
    static let version = 1
    static let maximumProfiles = 256
    private static let maximumRulesPerAsset = 32
    private static let forbiddenLiveFields: Set<String> = [
        "tunnelId", "processId", "isRunning", "running", "autoStart", "startAfterVerifiedConnection"
    ]

    static func decode(_ data: Data) -> PortForwardProfileSyncEnvelope? {
        guard !containsLiveState(data),
              let envelope = try? JSONDecoder().decode(PortForwardProfileSyncEnvelope.self, from: data) else {
            return nil
        }
        return try? validate(envelope)
    }

    static func encode(_ envelope: PortForwardProfileSyncEnvelope) throws -> Data {
        try JSONEncoder().encode(validate(envelope))
    }

    static func validate(_ envelope: PortForwardProfileSyncEnvelope) throws -> PortForwardProfileSyncEnvelope {
        guard envelope.kind == marker,
              envelope.version == version,
              envelope.updatedAtUnix > 0,
              envelope.profiles.count <= maximumProfiles,
              envelope.tombstones.count <= maximumProfiles * 4 else {
            throw ContractError.invalidEnvelope
        }
        let profiles = try envelope.profiles.map(normalize)
        let tombstones = try envelope.tombstones.map { item in
            guard item.deletedAtUnix > 0 else { throw ContractError.invalidEnvelope }
            return PortForwardProfileTombstoneWire(id: try canonicalUUID(item.id), deletedAtUnix: item.deletedAtUnix)
        }
        guard Set(profiles.map(\.id)).count == profiles.count,
              Set(tombstones.map(\.id)).count == tombstones.count,
              Dictionary(grouping: profiles, by: \.assetId).values.allSatisfy({ $0.count <= maximumRulesPerAsset }) else {
            throw ContractError.invalidEnvelope
        }
        return PortForwardProfileSyncEnvelope(
            kind: marker,
            version: version,
            updatedAtUnix: envelope.updatedAtUnix,
            profiles: profiles,
            tombstones: tombstones
        )
    }

    private static func normalize(_ item: PortForwardProfileWire) throws -> PortForwardProfileWire {
        let name = try normalizeText(item.name, maximum: 80)
        let bindHost = try normalizeHost(item.bindHost)
        guard ["local", "remote", "dynamicSocks5"].contains(item.mode),
              (0...65_535).contains(item.bindPort),
              item.createdAtUnix > 0,
              item.updatedAtUnix >= item.createdAtUnix else { throw ContractError.invalidProfile }
        let isDynamic = item.mode == "dynamicSocks5"
        let destinationHost = isDynamic ? "" : try normalizeHost(item.destinationHost)
        let destinationPort = isDynamic ? 0 : item.destinationPort
        guard isDynamic || (1...65_535).contains(destinationPort) else { throw ContractError.invalidProfile }
        return PortForwardProfileWire(
            id: try canonicalUUID(item.id),
            assetId: try canonicalUUID(item.assetId),
            name: name,
            mode: item.mode,
            bindHost: bindHost,
            bindPort: item.bindPort,
            destinationHost: destinationHost,
            destinationPort: destinationPort,
            createdAtUnix: item.createdAtUnix,
            updatedAtUnix: item.updatedAtUnix
        )
    }

    private static func containsLiveState(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        if !forbiddenLiveFields.isDisjoint(with: root.keys) { return true }
        guard let profiles = root["profiles"] as? [[String: Any]] else { return false }
        return profiles.contains { !forbiddenLiveFields.isDisjoint(with: $0.keys) }
    }

    private static func normalizeHost(_ raw: String) throws -> String {
        let host = try normalizeText(raw, maximum: 253)
        guard host.unicodeScalars.allSatisfy({ scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                !CharacterSet.controlCharacters.contains(scalar)
        }) else {
            throw ContractError.invalidProfile
        }
        return host
    }

    private static func normalizeText(_ raw: String, maximum: Int) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= maximum,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw ContractError.invalidProfile
        }
        return value
    }

    private static func canonicalUUID(_ raw: String) throws -> String {
        guard let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ContractError.invalidProfile
        }
        return id.uuidString.lowercased()
    }

    private enum ContractError: Error {
        case invalidEnvelope
        case invalidProfile
    }
}

enum PortForwardProfileStorageScope: String, Codable {
    case localOnly
    case endToEndEncrypted
}

struct SavedPortForwardProfile: Codable, Identifiable, Equatable {
    let id: UUID
    let assetID: UUID
    var name: String
    var mode: String
    var bindHost: String
    var bindPort: Int
    var destinationHost: String
    var destinationPort: Int
    let createdAtUnix: Int64
    var updatedAtUnix: Int64
    var syncScope: PortForwardProfileStorageScope
    var ownerAccountScope: String?
}

private struct PortForwardProfileVaultDocument: Codable {
    var version = 1
    var profiles: [SavedPortForwardProfile] = []
    var tombstones: [String: Int64] = [:]
    var remoteConfigID: UInt?
    var vectorClock = "{}"
    var payloadFingerprint = ""
}

/// Keychain-backed, account-isolated saved-profile library. The wire envelope
/// is portable; Linux can implement the same boundary with Secret Service.
@MainActor
final class PortForwardProfileStore: ObservableObject {
    static let shared = PortForwardProfileStore()
    @Published private(set) var profiles: [SavedPortForwardProfile] = []

    private let service = "com.orbitterm.port-forward-profiles.v1"
    private var activeScope: AccountScope?
    private var document = PortForwardProfileVaultDocument()

    func activate(username: String) throws {
        guard let scope = AccountScope(username: username) else { return }
        activeScope = scope
        let data = try KeychainDataStore.read(service: service, account: scope.storageIdentifier)
        document = data.flatMap { try? JSONDecoder().decode(PortForwardProfileVaultDocument.self, from: $0) }
            ?? PortForwardProfileVaultDocument()
        profiles = document.profiles
    }

    func deactivate() {
        activeScope = nil
        document = PortForwardProfileVaultDocument()
        profiles = []
    }

    func save(_ profile: SavedPortForwardProfile) throws {
        guard let scope = activeScope else { throw StoreError.accountLocked }
        var normalized = profile
        if normalized.syncScope == .endToEndEncrypted { normalized.ownerAccountScope = scope.storageIdentifier }
        guard normalized.syncScope == .localOnly || normalized.ownerAccountScope == scope.storageIdentifier else {
            throw StoreError.accountMismatch
        }
        document.profiles.removeAll { $0.id == normalized.id }
        document.profiles.append(normalized)
        if (document.tombstones[normalized.id.uuidString.lowercased(), default: 0] < normalized.updatedAtUnix) {
            document.tombstones.removeValue(forKey: normalized.id.uuidString.lowercased())
        }
        try persist()
    }

    func delete(_ id: UUID) throws {
        guard activeScope != nil else { throw StoreError.accountLocked }
        guard let removed = document.profiles.first(where: { $0.id == id }) else { return }
        document.profiles.removeAll { $0.id == id }
        if removed.syncScope == .endToEndEncrypted {
            let key = id.uuidString.lowercased()
            document.tombstones[key] = max(document.tombstones[key] ?? 0, Int64(Date().timeIntervalSince1970))
        }
        try persist()
    }

    func merge(_ remote: PortForwardProfileSyncEnvelope, scope: AccountScope) {
        for tombstone in remote.tombstones {
            document.tombstones[tombstone.id] = max(document.tombstones[tombstone.id] ?? 0, tombstone.deletedAtUnix)
        }
        var synced = Dictionary(uniqueKeysWithValues: document.profiles.filter { $0.syncScope == .endToEndEncrypted }.map { ($0.id.uuidString.lowercased(), $0) })
        let localOnly = document.profiles.filter { $0.syncScope == .localOnly }
        for wire in remote.profiles.sorted(by: { $0.updatedAtUnix < $1.updatedAtUnix }) {
            guard document.tombstones[wire.id, default: 0] < wire.updatedAtUnix,
                  !localOnly.contains(where: { $0.id.uuidString.caseInsensitiveCompare(wire.id) == .orderedSame }),
                  let id = UUID(uuidString: wire.id), let assetID = UUID(uuidString: wire.assetId) else { continue }
            if let local = synced[wire.id], local.updatedAtUnix > wire.updatedAtUnix { continue }
            synced[wire.id] = SavedPortForwardProfile(id: id, assetID: assetID, name: wire.name, mode: wire.mode,
                bindHost: wire.bindHost, bindPort: wire.bindPort, destinationHost: wire.destinationHost,
                destinationPort: wire.destinationPort, createdAtUnix: wire.createdAtUnix,
                updatedAtUnix: wire.updatedAtUnix, syncScope: .endToEndEncrypted,
                ownerAccountScope: scope.storageIdentifier)
        }
        synced = synced.filter { document.tombstones[$0.key, default: 0] < $0.value.updatedAtUnix }
        document.profiles = localOnly + synced.values
        profiles = document.profiles
    }

    func makeEnvelope(scope: AccountScope) -> PortForwardProfileSyncEnvelope {
        let wires = document.profiles.filter { $0.syncScope == .endToEndEncrypted && $0.ownerAccountScope == scope.storageIdentifier }.map {
            PortForwardProfileWire(id: $0.id.uuidString.lowercased(), assetId: $0.assetID.uuidString.lowercased(), name: $0.name,
                mode: $0.mode, bindHost: $0.bindHost, bindPort: $0.bindPort, destinationHost: $0.destinationHost,
                destinationPort: $0.destinationPort, createdAtUnix: $0.createdAtUnix, updatedAtUnix: $0.updatedAtUnix)
        }
        let tombstones = document.tombstones.map { PortForwardProfileTombstoneWire(id: $0.key, deletedAtUnix: $0.value) }
        let updated = max(Int64(Date().timeIntervalSince1970), max(wires.map(\.updatedAtUnix).max() ?? 0, tombstones.map(\.deletedAtUnix).max() ?? 0))
        return .init(kind: PortForwardProfileSyncContract.marker, version: 1, updatedAtUnix: updated, profiles: wires, tombstones: tombstones)
    }

    func persist() throws {
        guard let scope = activeScope else { throw StoreError.accountLocked }
        try KeychainDataStore.save(try JSONEncoder().encode(document), service: service, account: scope.storageIdentifier)
        profiles = document.profiles
    }

    func bump(_ raw: String) -> String {
        var clock = ((try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Int]) ?? [:]
        clock["port_forward_client", default: 0] += 1
        return String(data: (try? JSONSerialization.data(withJSONObject: clock, options: [.sortedKeys])) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    func syncMetadata() -> (remoteID: UInt?, vectorClock: String, payloadFingerprint: String) {
        (document.remoteConfigID, document.vectorClock, document.payloadFingerprint)
    }

    func recordRemoteMetadata(id: UInt, vectorClock: String, payloadFingerprint: String) throws {
        document.remoteConfigID = id
        document.vectorClock = vectorClock
        document.payloadFingerprint = payloadFingerprint
        try persist()
    }

    enum StoreError: Error { case accountLocked, accountMismatch, invalidEnvelope }
}
