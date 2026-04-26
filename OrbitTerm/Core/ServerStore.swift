import Foundation

enum ServerAuthMethod: String, Codable, CaseIterable, Identifiable {
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

struct ServerEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var group: String
    var host: String
    var port: Int
    var username: String
    var authMethod: ServerAuthMethod
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
            name: name,
            group: group,
            host: host,
            port: port,
            username: username,
            authMethod: authMethod.rawValue,
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

struct PortableServerConfig: Codable {
    let id: String
    let name: String
    let group: String
    let host: String
    let port: Int
    let username: String
    let authMethod: String
    let allowPasswordFallback: Bool
    let password: String
    let privateKeyContent: String
    let privateKeyPassphrase: String
    let keyReference: String
    let savedAtUnix: Int
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
        persist()
    }

    func remove(_ server: ServerEntry) {
        servers.removeAll { $0.id == server.id }
        if selectedServerID == server.id {
            selectedServerID = servers.first?.id
        }
        try? vault.delete(for: server.credentialID)
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

        var migrated = decoded
        var needsRewrite = false

        // 单次迁移：将旧版明文凭据搬入 Keychain。
        if !UserDefaults.standard.bool(forKey: migrationFlagKey) {
            for idx in migrated.indices {
                let legacyPassword = migrated[idx].legacyPassword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let legacyPrivateKey = migrated[idx].legacyPrivateKeyContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if !legacyPassword.isEmpty || !legacyPrivateKey.isEmpty {
                    let creds = ServerCredentials(password: legacyPassword, privateKeyContent: legacyPrivateKey)
                    try? vault.save(creds, for: migrated[idx].credentialID)
                    needsRewrite = true
                }
            }
            UserDefaults.standard.set(true, forKey: migrationFlagKey)
        }

        // 只要捕获到旧字段或首次迁移，均重写 defaults，确保彻底抹除明文字段。
        if migrated.contains(where: { ($0.legacyPassword?.isEmpty == false) || ($0.legacyPrivateKeyContent?.isEmpty == false) }) {
            needsRewrite = true
        }

        servers = migrated
        selectedServerID = migrated.first?.id

        if needsRewrite {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            persist()
        }
    }

    private func persist() {
        if let encoded = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(encoded, forKey: defaultsKey)
        }
    }
}
