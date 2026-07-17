import Foundation

@MainActor
final class ServerStore: ObservableObject {
    static let shared = ServerStore()

    @Published private(set) var servers: [ServerEntry] = []
    @Published var selectedServerID: UUID?

    private let legacyDefaultsKey = "orbitterm.servers.v1"
    private let legacyMigrationFlagKey = "orbitterm.servers.account-scope-migrated.v1"
    private let migrationFlagKey = "orbitterm.credentials.migrated.v1"
    private let vault = CredentialVault.shared
    private var accountScope: AccountScope?

    init() {}

    /// Makes this shared UI store represent exactly one authenticated account.
    /// Calls while signed out intentionally expose no cached assets.
    func activateAccount(username: String) {
        guard let scope = AccountScope(username: username) else {
            deactivateAccount()
            return
        }
        guard accountScope != scope else { return }

        accountScope = scope
        DeletedServerRegistry.shared.activate(scope: scope)
        load(scope: scope)
    }

    func deactivateAccount() {
        accountScope = nil
        servers = []
        selectedServerID = nil
        DeletedServerRegistry.shared.deactivate()
    }

    func isActiveAccount(_ username: String) -> Bool {
        AccountScope(username: username) == accountScope
    }

    func addOrUpdate(_ server: ServerEntry, credentials: ServerCredentials) {
        guard accountScope != nil else { return }
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
        guard accountScope != nil else { return }
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

    func applySyncedServers(_ synced: [ServerEntry], accountID: String) {
        guard isActiveAccount(accountID) else { return }
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
    func applySyncedServersIncrementally(
        _ synced: [ServerEntry],
        accountID: String,
        batchSize: Int = 8
    ) async -> Int {
        guard isActiveAccount(accountID) else { return 0 }
        guard !synced.isEmpty else { return 0 }

        var changedCount = 0
        let safeBatchSize = max(1, batchSize)
        for batchStart in stride(from: 0, to: synced.count, by: safeBatchSize) {
            guard isActiveAccount(accountID) else { return changedCount }
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

    func containsSameServers(_ synced: [ServerEntry], accountID: String) -> Bool {
        guard isActiveAccount(accountID) else { return false }
        guard !synced.isEmpty else { return true }
        let table = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        return synced.allSatisfy { table[$0.id] == $0 }
    }

    func remove(_ server: ServerEntry) {
        guard accountScope != nil else { return }
        servers.removeAll { $0.id == server.id }
        if selectedServerID == server.id {
            selectedServerID = servers.first?.id
        }
        DeletedServerRegistry.shared.markDeleted(server.id)
        try? vault.delete(for: server.credentialID)
        persist()
    }

    func removeMany(_ ids: Set<UUID>) {
        guard accountScope != nil else { return }
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

    /// 应用云端墓碑，不重复生成本地删除操作，避免形成删除回环。
    func applyRemoteDeletion(_ id: UUID, accountID: String) {
        guard isActiveAccount(accountID) else { return }
        guard let removed = servers.first(where: { $0.id == id }) else {
            DeletedServerRegistry.shared.clear(id)
            return
        }
        servers.removeAll { $0.id == id }
        if selectedServerID == id {
            selectedServerID = servers.first?.id
        }
        try? vault.delete(for: removed.credentialID)
        DeletedServerRegistry.shared.clear(id)
        persist()
    }

    func renameGroup(from oldName: String, to newName: String) {
        guard accountScope != nil else { return }
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
        guard accountScope != nil else { return }
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

    private func load(scope: AccountScope) {
        let scopedKey = scope.storageKey("orbitterm.servers.v2")
        if let data = UserDefaults.standard.data(forKey: scopedKey),
           let decoded = try? JSONDecoder().decode([ServerEntry].self, from: data) {
            servers = decoded
            selectedServerID = decoded.first?.id
            migrateLegacyCredentialsIfNeeded(decoded)
            return
        }

        // A legacy cache predates account scoping. It may only be claimed once,
        // by the first still-authenticated account that opens the upgraded app.
        // Subsequent accounts always start empty and pull their own cloud state.
        guard !UserDefaults.standard.bool(forKey: legacyMigrationFlagKey),
              let data = UserDefaults.standard.data(forKey: legacyDefaultsKey),
              let decoded = try? JSONDecoder().decode([ServerEntry].self, from: data) else {
            servers = []
            selectedServerID = nil
            return
        }

        servers = decoded
        selectedServerID = decoded.first?.id
        persist()
        UserDefaults.standard.set(true, forKey: legacyMigrationFlagKey)
        migrateLegacyCredentialsIfNeeded(decoded)
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
                UserDefaults.standard.removeObject(forKey: self.legacyDefaultsKey)
                self.persist()
            }
        }
    }

    private func persist() {
        guard let scope = accountScope,
              let encoded = try? JSONEncoder().encode(servers) else {
            return
        }
        UserDefaults.standard.set(encoded, forKey: scope.storageKey("orbitterm.servers.v2"))
    }
}
