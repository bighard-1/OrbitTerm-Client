import Foundation

@MainActor
final class ServerStore: ObservableObject {
    static let shared = ServerStore()

    @Published private(set) var servers: [ServerEntry] = []
    @Published var selectedServerID: UUID?

    private let legacyDefaultsKey = "orbitterm.servers.v1"
    private let legacyMigrationFlagKey = "orbitterm.servers.account-scope-migrated.v1"
    private let legacyMigrationOwnerKey = "orbitterm.servers.account-scope-migration-owner.v1"
    private let migrationFlagKey = "orbitterm.credentials.migrated.v1"
    private let vault = CredentialVault.shared
    private var accountScope: AccountScope?
    private var credentialMigrationOwner = OperationOwner()

    init() {}

    /// Makes this shared UI store represent exactly one authenticated account.
    /// Calls while signed out intentionally expose no cached assets.
    func activateAccount(username: String) {
        guard let scope = AccountScope(username: username) else {
            deactivateAccount()
            return
        }
        guard accountScope != scope else { return }

        credentialMigrationOwner.invalidate()
        accountScope = scope
        DeletedServerRegistry.shared.activate(scope: scope)
        load(scope: scope)
    }

    func deactivateAccount() {
        credentialMigrationOwner.invalidate()
        accountScope = nil
        servers = []
        selectedServerID = nil
        DeletedServerRegistry.shared.deactivate()
    }

    func isActiveAccount(_ username: String) -> Bool {
        AccountScope(username: username) == accountScope
    }

    @discardableResult
    func addOrUpdate(
        _ server: ServerEntry,
        credentials: ServerCredentials,
        jumpHostCredentials: ServerCredentials? = nil
    ) -> Bool {
        guard accountScope != nil else { return false }
        guard server.hasDistinctCredentialIDs,
              server.jumpHost == nil || jumpHostCredentials?.isEmpty == false else {
            // A route without its separate hop credential must never become a
            // persisted, deceptively connectable asset.
            return false
        }
        let existingServer = servers.first(where: { $0.id == server.id })
        let previousJumpCredentialID = existingServer?.jumpHost?.credentialID
        let previousTargetCredentials = try? vault.read(for: server.credentialID)
        let previousJumpCredentials = existingServer?.jumpHost.flatMap {
            try? vault.read(for: $0.credentialID)
        }
        do {
            try vault.save(credentials, for: server.credentialID)
            if let jumpHost = server.jumpHost, let jumpHostCredentials {
                try vault.save(jumpHostCredentials, for: jumpHost.credentialID)
            }
        } catch {
            restoreCredentialState(
                server: server,
                previousServer: existingServer,
                previousTargetCredentials: previousTargetCredentials,
                previousJumpCredentials: previousJumpCredentials
            )
            // 凭据保存失败时，不应继续写入资产配置，避免生成“无凭据资产”。
            return false
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
        if let previousJumpCredentialID,
           previousJumpCredentialID != server.jumpHost?.credentialID {
            try? vault.delete(for: previousJumpCredentialID)
        }
        persist()
        return true
    }

    @discardableResult
    func addOrUpdate(_ server: ServerEntry) -> Bool {
        guard accountScope != nil else { return false }
        let existingServer = servers.first(where: { $0.id == server.id })
        guard server.hasDistinctCredentialIDs else { return false }
        if let jumpHost = server.jumpHost {
            // This entry is used by metadata-only edits and restored sync data.
            // It must never make a new hop appear usable unless the separate
            // credential has already been written to the Keychain.
            guard let credentials = try? vault.read(for: jumpHost.credentialID),
                  !credentials.isEmpty else {
                return false
            }
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
        if let previousJumpCredentialID = existingServer?.jumpHost?.credentialID,
           previousJumpCredentialID != server.jumpHost?.credentialID {
            try? vault.delete(for: previousJumpCredentialID)
        }
        persist()
        return true
    }

    private func restoreCredentialState(
        server: ServerEntry,
        previousServer: ServerEntry?,
        previousTargetCredentials: ServerCredentials?,
        previousJumpCredentials: ServerCredentials?
    ) {
        if let previousTargetCredentials {
            try? vault.save(previousTargetCredentials, for: server.credentialID)
        } else {
            try? vault.delete(for: server.credentialID)
        }

        guard let previousJumpHost = previousServer?.jumpHost else {
            if let configuredJumpHost = server.jumpHost {
                try? vault.delete(for: configuredJumpHost.credentialID)
            }
            return
        }
        if let previousJumpCredentials {
            try? vault.save(previousJumpCredentials, for: previousJumpHost.credentialID)
        }
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
        deleteCredentials(for: server)
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
            deleteCredentials(for: item)
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
        deleteCredentials(for: removed)
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
            deleteCredentials(for: item)
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
            let ownsInterruptedLegacyMigration =
                UserDefaults.standard.string(forKey: legacyMigrationOwnerKey) == scope.storageIdentifier
            let recoveryEntries: [ServerEntry]
            if ownsInterruptedLegacyMigration,
               let legacyData = UserDefaults.standard.data(forKey: legacyDefaultsKey),
               let legacyEntries = try? JSONDecoder().decode([ServerEntry].self, from: legacyData) {
                let activeIDs = Set(decoded.map(\.id))
                recoveryEntries = legacyEntries.filter { activeIDs.contains($0.id) }
            } else {
                recoveryEntries = decoded
            }
            migrateLegacyCredentialsIfNeeded(
                recoveryEntries,
                scope: scope,
                commitsLegacyCache: ownsInterruptedLegacyMigration
            )
            return
        }

        // A legacy cache predates account scoping. It may only be claimed once,
        // by the first still-authenticated account that opens the upgraded app.
        // Subsequent accounts always start empty and pull their own cloud state.
        let reservedOwner = UserDefaults.standard.string(forKey: legacyMigrationOwnerKey)
        guard AccountMigrationReservationPolicy.canResume(
                migrationCompleted: UserDefaults.standard.bool(forKey: legacyMigrationFlagKey),
                reservedOwner: reservedOwner,
                requestingScope: scope.storageIdentifier
              ),
              let data = UserDefaults.standard.data(forKey: legacyDefaultsKey),
              let decoded = try? JSONDecoder().decode([ServerEntry].self, from: data) else {
            servers = []
            selectedServerID = nil
            return
        }

        // Reserve the unscoped source for exactly one opaque account before
        // any asynchronous Keychain write. If the process dies, only the same
        // authenticated account can resume the migration.
        UserDefaults.standard.set(scope.storageIdentifier, forKey: legacyMigrationOwnerKey)
        servers = decoded
        selectedServerID = decoded.first?.id
        migrateLegacyCredentialsIfNeeded(decoded, scope: scope, commitsLegacyCache: true)
    }

    private func migrateLegacyCredentialsIfNeeded(
        _ entries: [ServerEntry],
        scope: AccountScope,
        commitsLegacyCache: Bool
    ) {
        let requiresMigration = commitsLegacyCache ||
            !UserDefaults.standard.bool(forKey: migrationFlagKey) ||
            entries.contains(where: { ($0.legacyPassword?.isEmpty == false) || ($0.legacyPrivateKeyContent?.isEmpty == false) })
        guard requiresMigration else { return }
        let lease = credentialMigrationOwner.begin(scope: .account(scope.storageIdentifier))

        Task(priority: .background) { [weak self] in
            guard let self else { return }
            var migratedAny = false
            for entry in entries {
                guard self.credentialMigrationOwner.owns(
                    lease,
                    scope: .account(scope.storageIdentifier)
                ), self.accountScope == scope else { return }
                let legacyPassword = entry.legacyPassword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let legacyPrivateKey = entry.legacyPrivateKeyContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !legacyPassword.isEmpty || !legacyPrivateKey.isEmpty {
                    let creds = ServerCredentials(password: legacyPassword, privateKeyContent: legacyPrivateKey)
                    do {
                        try self.vault.save(creds, for: entry.credentialID)
                    } catch {
                        // Keep the legacy source intact. A later activation can
                        // retry; a partial Keychain failure must never be
                        // recorded as a completed migration.
                        return
                    }
                    migratedAny = true
                }
                await Task.yield()
            }

            guard self.credentialMigrationOwner.owns(
                lease,
                scope: .account(scope.storageIdentifier)
            ), self.accountScope == scope else { return }
            if migratedAny || commitsLegacyCache {
                guard self.persist() else { return }
            }
            UserDefaults.standard.set(true, forKey: self.migrationFlagKey)
            if commitsLegacyCache {
                UserDefaults.standard.set(true, forKey: self.legacyMigrationFlagKey)
                UserDefaults.standard.removeObject(forKey: self.legacyDefaultsKey)
                UserDefaults.standard.removeObject(forKey: self.legacyMigrationOwnerKey)
            }
        }
    }

    @discardableResult
    private func persist() -> Bool {
        guard let scope = accountScope,
              let encoded = try? JSONEncoder().encode(servers) else {
            return false
        }
        UserDefaults.standard.set(encoded, forKey: scope.storageKey("orbitterm.servers.v2"))
        return true
    }

    private func deleteCredentials(for server: ServerEntry) {
        for credentialID in server.credentialIDs {
            try? vault.delete(for: credentialID)
        }
    }
}
