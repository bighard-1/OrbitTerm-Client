import Foundation

struct ServerAddPrefill: Equatable {
    var name: String
    var group: String
    var host: String
    var port: Int
    var username: String
}

struct DeepLinkIntent: Identifiable, Equatable {
    let id = UUID()
    let host: String
    let port: Int
    let username: String
    let suggestedName: String

    var prefill: ServerAddPrefill {
        ServerAddPrefill(
            name: suggestedName,
            group: "",
            host: host,
            port: port,
            username: username
        )
    }
}

@MainActor
final class DeepLinkManager: ObservableObject {
    static let shared = DeepLinkManager()

    @Published var pendingIntent: DeepLinkIntent?

    private init() {}

    func handle(url: URL) {
        guard let intent = parse(url: url) else { return }
        pendingIntent = intent
    }

    func consumePendingIntent() {
        pendingIntent = nil
    }

    private func parse(url: URL) -> DeepLinkIntent? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "ssh":
            return parseSSH(url: url)
        case "orbitterm":
            return parseOrbitTerm(url: url)
        default:
            return nil
        }
    }

    private func parseSSH(url: URL) -> DeepLinkIntent? {
        guard let comp = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = safeHost(comp.host) else {
            return nil
        }

        let username: String
        if let rawUsername = comp.user {
            guard let validUsername = safeUsername(rawUsername) else { return nil }
            username = validUsername
        } else {
            username = "root"
        }
        let port = comp.port ?? 22
        guard (1...65535).contains(port) else { return nil }

        return DeepLinkIntent(
            host: host,
            port: port,
            username: username.isEmpty ? "root" : username,
            suggestedName: "\(host):\(port)"
        )
    }

    private func parseOrbitTerm(url: URL) -> DeepLinkIntent? {
        guard let comp = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let route = url.host?.lowercased() ?? comp.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard route == "connect" || route.isEmpty else { return nil }

        let query = Dictionary((comp.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { first, _ in first })

        guard let host = safeHost(query["host"] ?? comp.host) else { return nil }

        let username: String
        if let rawUsername = query["username"] ?? query["user"] {
            guard let validUsername = safeUsername(rawUsername) else { return nil }
            username = validUsername
        } else {
            username = "root"
        }

        let port = query["port"].flatMap(parsePort) ?? (query["port"] == nil ? 22 : 0)
        guard (1...65535).contains(port) else { return nil }

        let name = safeDisplayName(query["name"])
        return DeepLinkIntent(
            host: host,
            port: port,
            username: username.isEmpty ? "root" : username,
            suggestedName: (name?.isEmpty == false ? name! : "\(host):\(port)")
        )
    }

    private func safeHost(_ raw: String?) -> String? {
        guard let value = safeField(raw, rejectsWhitespace: true), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func safeUsername(_ raw: String?) -> String? {
        guard let value = safeField(raw, rejectsWhitespace: true), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func safeDisplayName(_ raw: String?) -> String? {
        safeField(raw, rejectsWhitespace: false)
    }

    private func safeField(_ raw: String?, rejectsWhitespace: Bool) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        guard !rejectsWhitespace || value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }
        return value
    }

    private func parsePort(_ raw: String) -> Int? {
        guard !raw.isEmpty,
              raw.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              let port = Int(raw) else {
            return nil
        }
        return port
    }
}
