import Foundation

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

    /// 应用云端墓碑，不重复生成本地删除操作，避免形成删除回环。
    func applyRemoteDeletion(_ id: UUID) {
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
