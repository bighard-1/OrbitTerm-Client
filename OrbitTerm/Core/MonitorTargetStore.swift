import Foundation

struct MonitorTargetLoadResult {
    let targets: [MonitorTargetConfig]
    let needsRewrite: Bool
}

struct MonitorTargetStore {
    private let userDefaultsKey = "monitor.targets.v1"
    private let migrationFlagKey = "monitor.targets.credentials.migrated.v1"
    private let userDefaults: UserDefaults
    private let vault: CredentialVault

    init(userDefaults: UserDefaults = .standard, vault: CredentialVault = .shared) {
        self.userDefaults = userDefaults
        self.vault = vault
    }

    func load() -> MonitorTargetLoadResult {
        guard let data = userDefaults.data(forKey: userDefaultsKey),
              let targets = try? JSONDecoder().decode([MonitorTargetConfig].self, from: data),
              !targets.isEmpty else {
            return MonitorTargetLoadResult(targets: [Self.defaultTarget()], needsRewrite: false)
        }

        var needsRewrite = false
        if !userDefaults.bool(forKey: migrationFlagKey) {
            for target in targets {
                let legacy = target.legacyPassword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !legacy.isEmpty {
                    try? vault.save(ServerCredentials(password: legacy, privateKeyContent: ""), for: target.credentialID)
                    needsRewrite = true
                }
            }
            userDefaults.set(true, forKey: migrationFlagKey)
        }

        if targets.contains(where: { $0.legacyPassword?.isEmpty == false }) {
            needsRewrite = true
        }

        return MonitorTargetLoadResult(targets: targets, needsRewrite: needsRewrite)
    }

    func save(_ targets: [MonitorTargetConfig]) {
        if let data = try? JSONEncoder().encode(targets) {
            userDefaults.set(data, forKey: userDefaultsKey)
        }
    }

    func clear() {
        userDefaults.removeObject(forKey: userDefaultsKey)
    }

    static func defaultTarget() -> MonitorTargetConfig {
        MonitorTargetConfig(
            name: "Default",
            host: "",
            username: ""
        )
    }
}
