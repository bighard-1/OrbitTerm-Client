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
              let host = comp.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return nil
        }

        let username = (comp.user ?? "root").trimmingCharacters(in: .whitespacesAndNewlines)
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

        let host = query["host"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? comp.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !host.isEmpty else { return nil }

        let username = query["username"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? query["user"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "root"

        let port = Int(query["port"] ?? "") ?? 22
        guard (1...65535).contains(port) else { return nil }

        let name = query["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DeepLinkIntent(
            host: host,
            port: port,
            username: username.isEmpty ? "root" : username,
            suggestedName: (name?.isEmpty == false ? name! : "\(host):\(port)")
        )
    }
}
