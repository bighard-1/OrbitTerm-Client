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
    var password: String
    var privateKeyPath: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        group: String = "",
        host: String,
        port: Int = 22,
        username: String,
        authMethod: ServerAuthMethod,
        password: String = "",
        privateKeyPath: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.password = password
        self.privateKeyPath = privateKeyPath
        self.createdAt = createdAt
    }

    var displayGroup: String {
        let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未分组" : trimmed
    }

    var endpointText: String {
        "\(host):\(port)"
    }

    // 跨端同步时使用的平台无关模型，避免携带 macOS 私有路径。
    func makePortableConfig(savedAtUnix: Int) -> PortableServerConfig {
        PortableServerConfig(
            id: id.uuidString,
            name: name,
            group: group,
            host: host,
            port: port,
            username: username,
            authMethod: authMethod.rawValue,
            password: authMethod == .password ? password : "",
            keyReference: authMethod == .key ? sanitizeKeyReference(privateKeyPath) : "",
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
    let password: String
    let keyReference: String
    let savedAtUnix: Int
}

@MainActor
final class ServerStore: ObservableObject {
    @Published private(set) var servers: [ServerEntry] = []
    @Published var selectedServerID: UUID?

    private let defaultsKey = "orbitterm.servers.v1"

    init() {
        load()
    }

    func addOrUpdate(_ server: ServerEntry) {
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
        servers = decoded
        selectedServerID = decoded.first?.id
    }

    private func persist() {
        if let encoded = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(encoded, forKey: defaultsKey)
        }
    }
}
