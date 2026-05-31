import Foundation

enum ServerAuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case key

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .password: return "密码"
        case .key: return "密钥"
        }
    }
}

enum ServerTransportProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case ssh
    case telnet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ssh: return "SSH"
        case .telnet: return "Telnet"
        }
    }
}

enum NetworkDeviceProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case huaweiVRP
    case h3cComware
    case ciscoIOS
    case ciscoASA
    case juniperJunos
    case fortinetFortiGate
    case paloAltoPANOS
    case mikrotikRouterOS
    case ruijie
    case sangfor
    case hillstone
    case checkPoint
    case f5BIGIP
    case generic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "自动识别"
        case .huaweiVRP: return "华为 VRP / USG"
        case .h3cComware: return "H3C Comware"
        case .ciscoIOS: return "Cisco IOS / IOS XE"
        case .ciscoASA: return "Cisco ASA"
        case .juniperJunos: return "Juniper Junos"
        case .fortinetFortiGate: return "Fortinet FortiGate"
        case .paloAltoPANOS: return "Palo Alto PAN-OS"
        case .mikrotikRouterOS: return "MikroTik RouterOS"
        case .ruijie: return "锐捷 Ruijie"
        case .sangfor: return "深信服 Sangfor"
        case .hillstone: return "山石 Hillstone"
        case .checkPoint: return "Check Point"
        case .f5BIGIP: return "F5 BIG-IP"
        case .generic: return "通用 Telnet"
        }
    }
}

struct ServerEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var group: String
    var host: String
    var port: Int
    var username: String
    var authMethod: ServerAuthMethod
    var transport: ServerTransportProtocol
    var networkDeviceProfile: NetworkDeviceProfile
    var allowPasswordFallback: Bool
    var credentialID: UUID
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        group: String = "",
        host: String,
        port: Int = 22,
        username: String,
        authMethod: ServerAuthMethod,
        transport: ServerTransportProtocol = .ssh,
        networkDeviceProfile: NetworkDeviceProfile = .auto,
        allowPasswordFallback: Bool = true,
        credentialID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.transport = transport
        self.networkDeviceProfile = networkDeviceProfile
        self.allowPasswordFallback = allowPasswordFallback
        self.credentialID = credentialID ?? id
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case group
        case host
        case port
        case username
        case authMethod
        case transport
        case networkDeviceProfile
        case allowPasswordFallback
        case credentialID
        case createdAt
        // 旧版本字段，仅用于迁移读取，不再写回。
        case password
        case privateKeyPath
    }

    // 旧版本的明文字段只在迁移阶段短暂驻留内存，不参与持久化写回。
    var legacyPassword: String?
    var legacyPrivateKeyContent: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? ""
        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try container.decode(String.self, forKey: .username)
        authMethod = try container.decodeIfPresent(ServerAuthMethod.self, forKey: .authMethod) ?? .password
        transport = try container.decodeIfPresent(ServerTransportProtocol.self, forKey: .transport) ?? .ssh
        networkDeviceProfile = try container.decodeIfPresent(NetworkDeviceProfile.self, forKey: .networkDeviceProfile) ?? .auto
        allowPasswordFallback = try container.decodeIfPresent(Bool.self, forKey: .allowPasswordFallback) ?? true
        credentialID = try container.decodeIfPresent(UUID.self, forKey: .credentialID) ?? id
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        legacyPassword = try container.decodeIfPresent(String.self, forKey: .password)
        legacyPrivateKeyContent = try container.decodeIfPresent(String.self, forKey: .privateKeyPath)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(group, forKey: .group)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(authMethod, forKey: .authMethod)
        try container.encode(transport, forKey: .transport)
        try container.encode(networkDeviceProfile, forKey: .networkDeviceProfile)
        try container.encode(allowPasswordFallback, forKey: .allowPasswordFallback)
        try container.encode(credentialID, forKey: .credentialID)
        try container.encode(createdAt, forKey: .createdAt)
    }

    var displayGroup: String {
        let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未分组" : trimmed
    }

    var endpointText: String {
        "\(host):\(port)"
    }

    // 跨端同步时使用的平台无关模型，避免携带 macOS 私有路径。
    func makePortableConfig(savedAtUnix: Int, credentials: ServerCredentials?) -> PortableServerConfig {
        // P1 修复：同步模型不再依据 authMethod 过滤凭据字段。
        // 只要本地 Keychain 有值，就要全量打入同一个加密 Blob，确保跨端拉取完整恢复。
        let password = credentials?.password ?? ""
        let privateKeyContent = credentials?.privateKeyContent ?? ""
        let privateKeyPassphrase = credentials?.privateKeyPassphrase ?? ""
        return PortableServerConfig(
            id: id.uuidString,
            credentialID: credentialID.uuidString,
            name: name,
            group: group,
            host: host,
            port: port,
            username: username,
            authMethod: authMethod.rawValue,
            transport: transport.rawValue,
            networkDeviceProfile: networkDeviceProfile.rawValue,
            allowPasswordFallback: allowPasswordFallback,
            password: password,
            privateKeyContent: privateKeyContent,
            privateKeyPassphrase: privateKeyPassphrase,
            keyReference: sanitizeKeyReference(privateKeyContent),
            savedAtUnix: savedAtUnix
        )
    }

    private func sanitizeKeyReference(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // 仅保留文件名作为引用，禁止上传本机绝对路径。
        let last = URL(fileURLWithPath: trimmed).lastPathComponent
        let filtered = last.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "."
        }
        return String(String.UnicodeScalarView(filtered))
    }
}

struct PortableServerConfig: Codable, Equatable {
    let id: String
    let credentialID: String
    let name: String
    let group: String
    let host: String
    let port: Int
    let username: String
    let authMethod: String
    let transport: String
    let networkDeviceProfile: String
    let allowPasswordFallback: Bool
    let password: String
    let privateKeyContent: String
    let privateKeyPassphrase: String
    let keyReference: String
    let savedAtUnix: Int

    enum CodingKeys: String, CodingKey {
        case id
        case credentialID
        case name
        case group
        case host
        case port
        case username
        case authMethod
        case transport
        case networkDeviceProfile
        case allowPasswordFallback
        case password
        case privateKeyContent
        case privateKeyPassphrase
        case keyReference
        case savedAtUnix
    }

    init(
        id: String,
        credentialID: String,
        name: String,
        group: String,
        host: String,
        port: Int,
        username: String,
        authMethod: String,
        transport: String,
        networkDeviceProfile: String = NetworkDeviceProfile.auto.rawValue,
        allowPasswordFallback: Bool,
        password: String,
        privateKeyContent: String,
        privateKeyPassphrase: String,
        keyReference: String,
        savedAtUnix: Int
    ) {
        self.id = id
        self.credentialID = credentialID
        self.name = name
        self.group = group
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.transport = transport
        self.networkDeviceProfile = networkDeviceProfile
        self.allowPasswordFallback = allowPasswordFallback
        self.password = password
        self.privateKeyContent = privateKeyContent
        self.privateKeyPassphrase = privateKeyPassphrase
        self.keyReference = keyReference
        self.savedAtUnix = savedAtUnix
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        credentialID = try c.decodeIfPresent(String.self, forKey: .credentialID) ?? id
        name = try c.decode(String.self, forKey: .name)
        group = try c.decode(String.self, forKey: .group)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        authMethod = try c.decode(String.self, forKey: .authMethod)
        transport = try c.decodeIfPresent(String.self, forKey: .transport) ?? ServerTransportProtocol.ssh.rawValue
        networkDeviceProfile = try c.decodeIfPresent(String.self, forKey: .networkDeviceProfile) ?? NetworkDeviceProfile.auto.rawValue
        allowPasswordFallback = try c.decode(Bool.self, forKey: .allowPasswordFallback)
        password = try c.decode(String.self, forKey: .password)
        privateKeyContent = try c.decode(String.self, forKey: .privateKeyContent)
        privateKeyPassphrase = try c.decodeIfPresent(String.self, forKey: .privateKeyPassphrase) ?? ""
        keyReference = try c.decodeIfPresent(String.self, forKey: .keyReference) ?? ""
        savedAtUnix = try c.decodeIfPresent(Int.self, forKey: .savedAtUnix) ?? Int(Date().timeIntervalSince1970)
    }
}

/// 本地删除墓碑：用于解决“本地已删除，但云端旧副本下次拉取又复活”的问题。
/// 只保存资产 UUID 和删除时间，不包含任何凭据或敏感信息。
final class DeletedServerRegistry {
    static let shared = DeletedServerRegistry()

    private let defaultsKey = "orbitterm.deleted.servers.v1"
    private let retention: TimeInterval = 60 * 60 * 24 * 90
    private let lock = NSLock()

    private init() {}

    func markDeleted(_ id: UUID) {
        markDeleted([id])
    }

    func markDeleted(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        var map = readMapUnlocked()
        let now = Date().timeIntervalSince1970
        for id in ids {
            map[id.uuidString] = now
        }
        persistUnlocked(pruned(map, now: now))
    }

    func clear(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        var map = readMapUnlocked()
        map.removeValue(forKey: id.uuidString)
        persistUnlocked(map)
    }

    func isDeleted(idString: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return readMapUnlocked()[idString] != nil
    }

    func snapshot() -> [String: TimeInterval] {
        lock.lock()
        defer { lock.unlock() }

        let now = Date().timeIntervalSince1970
        let map = pruned(readMapUnlocked(), now: now)
        persistUnlocked(map)
        return map
    }

    private func readMapUnlocked() -> [String: TimeInterval] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let map = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else {
            return [:]
        }
        return map
    }

    private func persistUnlocked(_ map: [String: TimeInterval]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func pruned(_ map: [String: TimeInterval], now: TimeInterval) -> [String: TimeInterval] {
        map.filter { now - $0.value <= retention }
    }
}

@MainActor
final class ServerStore: ObservableObject {
    static let shared = ServerStore()

    @Published private(set) var servers: [ServerEntry] = []
    @Published var selectedServerID: UUID?

    private let defaultsKey = "orbitterm.servers.v1"
    private let migrationFlagKey = "orbitterm.credentials.migrated.v1"
    private let vault = CredentialVault.shared

    init() {
        load()
    }

    func addOrUpdate(_ server: ServerEntry, credentials: ServerCredentials) {
        do {
            try vault.save(credentials, for: server.credentialID)
        } catch {
            // 凭据保存失败时，不应继续写入资产配置，避免生成“无凭据资产”。
            return
        }

        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
        } else {
            servers.append(server)
        }
        servers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if selectedServerID == nil {
            selectedServerID = server.id
        }
        DeletedServerRegistry.shared.clear(server.id)
        persist()
    }

    func addOrUpdate(_ server: ServerEntry) {
        // 兼容旧调用：无新凭据时保留现有 Keychain 内容，仅更新普通配置。
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
        } else {
            servers.append(server)
        }
        servers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if selectedServerID == nil {
            selectedServerID = server.id
        }
        DeletedServerRegistry.shared.clear(server.id)
        persist()
    }

    func applySyncedServers(_ synced: [ServerEntry]) {
        guard !synced.isEmpty else { return }
        var table = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        for item in synced {
            table[item.id] = item
        }
        servers = table.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if selectedServerID == nil {
            selectedServerID = servers.first?.id
        }
        persist()
    }

    @MainActor
    func applySyncedServersIncrementally(_ synced: [ServerEntry], batchSize: Int = 8) async -> Int {
        guard !synced.isEmpty else { return 0 }

        var changedCount = 0
        let safeBatchSize = max(1, batchSize)
        for batchStart in stride(from: 0, to: synced.count, by: safeBatchSize) {
            let batchEnd = min(batchStart + safeBatchSize, synced.count)
            let batch = synced[batchStart..<batchEnd]
            var table = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
            var batchChanged = false

            for item in batch where table[item.id] != item {
                table[item.id] = item
                batchChanged = true
                changedCount += 1
            }

            if batchChanged {
                servers = table.values.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                if selectedServerID == nil {
                    selectedServerID = servers.first?.id
                }
                persist()
            }

            // 主动让出主线程，让首屏、滚动和点击不被大量资产合并抢占。
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        return changedCount
    }

    func containsSameServers(_ synced: [ServerEntry]) -> Bool {
        guard !synced.isEmpty else { return true }
        let table = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        return synced.allSatisfy { table[$0.id] == $0 }
    }

    func remove(_ server: ServerEntry) {
        servers.removeAll { $0.id == server.id }
        if selectedServerID == server.id {
            selectedServerID = servers.first?.id
        }
        DeletedServerRegistry.shared.markDeleted(server.id)
        try? vault.delete(for: server.credentialID)
        persist()
    }

    func removeMany(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let removed = servers.filter { ids.contains($0.id) }
        servers.removeAll { ids.contains($0.id) }
        if let selected = selectedServerID, ids.contains(selected) {
            selectedServerID = servers.first?.id
        }
        DeletedServerRegistry.shared.markDeleted(Array(ids))
        for item in removed {
            try? vault.delete(for: item.credentialID)
        }
        persist()
    }

    func renameGroup(from oldName: String, to newName: String) {
        let trimmedNew = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNew.isEmpty else { return }
        let targetOld = oldName == "未分组" ? "" : oldName
        var changed = false
        for idx in servers.indices {
            if servers[idx].displayGroup == oldName || servers[idx].group == targetOld {
                servers[idx].group = trimmedNew
                changed = true
            }
        }
        if changed { persist() }
    }

    func removeGroup(_ groupName: String) {
        let target = groupName == "未分组" ? "" : groupName
        let removed = servers.filter { $0.displayGroup == groupName || $0.group == target }
        guard !removed.isEmpty else { return }
        let removedIDs = Set(removed.map(\.id))
        servers.removeAll { removedIDs.contains($0.id) }
        if let selected = selectedServerID, removedIDs.contains(selected) {
            selectedServerID = servers.first?.id
        }
        DeletedServerRegistry.shared.markDeleted(Array(removedIDs))
        for item in removed {
            try? vault.delete(for: item.credentialID)
        }
        persist()
    }

    func select(_ server: ServerEntry) {
        selectedServerID = server.id
    }

    var selectedServer: ServerEntry? {
        guard let selectedServerID else { return servers.first }
        return servers.first(where: { $0.id == selectedServerID })
    }

    var groupedServers: [(group: String, items: [ServerEntry])] {
        let grouped = Dictionary(grouping: servers, by: { $0.displayGroup })
        return grouped.keys.sorted().map { key in
            (group: key, items: grouped[key] ?? [])
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([ServerEntry].self, from: data) else {
            servers = []
            return
        }

        let migrated = decoded
        servers = migrated
        selectedServerID = migrated.first?.id
        migrateLegacyCredentialsIfNeeded(migrated)
    }

    private func migrateLegacyCredentialsIfNeeded(_ entries: [ServerEntry]) {
        let requiresMigration = !UserDefaults.standard.bool(forKey: migrationFlagKey) ||
            entries.contains(where: { ($0.legacyPassword?.isEmpty == false) || ($0.legacyPrivateKeyContent?.isEmpty == false) })
        guard requiresMigration else { return }

        Task(priority: .background) { [weak self] in
            guard let self else { return }
            var migratedAny = false
            for entry in entries {
                let legacyPassword = entry.legacyPassword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let legacyPrivateKey = entry.legacyPrivateKeyContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !legacyPassword.isEmpty || !legacyPrivateKey.isEmpty {
                    let creds = ServerCredentials(password: legacyPassword, privateKeyContent: legacyPrivateKey)
                    try? self.vault.save(creds, for: entry.credentialID)
                    migratedAny = true
                }
            }

            UserDefaults.standard.set(true, forKey: self.migrationFlagKey)
            if migratedAny {
                UserDefaults.standard.removeObject(forKey: self.defaultsKey)
                self.persist()
            }
        }
    }

    private func persist() {
        if let encoded = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(encoded, forKey: defaultsKey)
        }
    }
}
