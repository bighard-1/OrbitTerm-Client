import Foundation

struct TelnetTargetIdentity: Codable, Hashable, Sendable {
    let serverID: UUID
    let host: String
    let port: Int

    init(serverID: UUID, host: String, port: Int) {
        self.serverID = serverID
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.port = port
    }
}

enum TelnetAccessDecision: Equatable, Sendable {
    case preferenceDisabled
    case requiresConfirmation
    case allowed
}

@MainActor
final class TelnetAccessPolicy {
    static let enabledStorageKey = "orbitterm.telnet.explicit.enabled.v2"
    static let confirmedTargetsStorageKey = "orbitterm.telnet.confirmed-targets.v1"
    static let shared = TelnetAccessPolicy()

    private static let maximumConfirmedTargets = 256
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var isEnabled: Bool {
        userDefaults.bool(forKey: Self.enabledStorageKey)
    }

    func setEnabled(_ enabled: Bool) {
        let wasEnabled = isEnabled
        userDefaults.set(enabled, forKey: Self.enabledStorageKey)
        if !enabled || !wasEnabled {
            forgetAllConfirmations()
        }
    }

    func decision(for target: TelnetTargetIdentity) -> TelnetAccessDecision {
        guard isEnabled else { return .preferenceDisabled }
        return confirmedTargets().contains(target) ? .allowed : .requiresConfirmation
    }

    func confirm(_ target: TelnetTargetIdentity) {
        guard isEnabled else { return }
        var targets = confirmedTargets().filter { $0 != target }
        targets.append(target)
        if targets.count > Self.maximumConfirmedTargets {
            targets.removeFirst(targets.count - Self.maximumConfirmedTargets)
        }
        persist(targets)
    }

    func forgetAllConfirmations() {
        userDefaults.removeObject(forKey: Self.confirmedTargetsStorageKey)
    }

    private func confirmedTargets() -> [TelnetTargetIdentity] {
        guard let data = userDefaults.data(forKey: Self.confirmedTargetsStorageKey),
              let targets = try? JSONDecoder().decode([TelnetTargetIdentity].self, from: data) else {
            return []
        }
        return targets
    }

    private func persist(_ targets: [TelnetTargetIdentity]) {
        guard let data = try? JSONEncoder().encode(targets) else { return }
        userDefaults.set(data, forKey: Self.confirmedTargetsStorageKey)
    }
}

struct TelnetRiskPresentationRoute: Identifiable, Equatable, Sendable {
    let workspaceID: UUID
    let target: TelnetTargetIdentity
    let displayName: String

    var id: UUID { workspaceID }
    var endpoint: String { "\(target.host):\(target.port)" }
}
