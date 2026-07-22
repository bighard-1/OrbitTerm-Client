import SwiftUI

struct AssetManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security

    @ObservedObject var store: ServerStore
    let onEdit: (ServerEntry) -> Void
    let onConnect: (ServerEntry) -> Void

    @State private var query = ""
    @State private var noticeText: String = ""
    @State private var noticeKind: SecurityStatusKind? = nil
    @State private var policyChangingID: UUID?
    @State private var keySetupServer: ServerEntry?
    @State private var showingBulkAdd = false
    @State private var selectedAssetIDs: Set<UUID> = []
    @State private var showingBulkDeleteConfirmation = false

    private let vault = CredentialVault.shared
    @StateObject private var orbitManager = OrbitManager()
    @StateObject private var syncService = SyncService.shared

    var body: some View {
        NavigationStack {
            List(selection: $selectedAssetIDs) {
                if filteredServers.isEmpty {
                    ContentUnavailableView(
                        "暂无匹配资产",
                        systemImage: "server.rack",
                        description: Text(query.isEmpty ? "还没有已保存服务器" : "尝试更换搜索关键词")
                    )
                } else {
                    ForEach(groupedFiltered, id: \.group) { section in
                        Section(section.group) {
                            ForEach(section.items) { server in
                                assetRow(for: server)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppChromeBackground())
            .searchable(text: $query, prompt: "搜索名称 / 主机 / 用户名")
            .onChange(of: query) { _, _ in
                // Keep batch actions scoped to rows the user can currently see;
                // changing a search must never leave hidden assets selected.
                selectedAssetIDs.formIntersection(Set(filteredServers.map(\.id)))
            }
            .navigationTitle("资产管理")
            .safeAreaInset(edge: .bottom) { bottomStatusBar }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    AssetManagerCloseButton(action: { dismiss() })
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingBulkAdd = true
                    } label: {
                        Label("批量添加", systemImage: "square.stack.3d.up.fill")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("选择当前结果") {
                            selectedAssetIDs = Set(filteredServers.map(\.id))
                        }
                        Button("取消选择") {
                            selectedAssetIDs.removeAll()
                        }
                        .disabled(selectedAssetIDs.isEmpty)
                    } label: {
                        Label("批量选择", systemImage: "checklist")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        showingBulkDeleteConfirmation = true
                    } label: {
                        Label("删除所选", systemImage: "trash")
                    }
                    .disabled(selectedAssetIDs.isEmpty)
                }
            }
        }
        .tint(palette.accentPrimary.color)
        .sheet(item: $keySetupServer) { server in
            QuickKeySetupSheet(server: server, store: store) { status in
                switch status {
                case let .saved(message):
                    noticeKind = .success
                    noticeText = message
                case let .failed(message):
                    noticeKind = .warning
                    noticeText = message
                }
            }
            .injectAppTheme()
        }
        .sheet(isPresented: $showingBulkAdd) {
            BulkAddAssetsSheet(store: store) { count in
                noticeKind = count > 0 ? .success : .warning
                noticeText = count > 0 ? "已批量添加 \(count) 个资产，并已进入后台同步" : "未添加资产，请检查输入格式"
            }
            .environmentObject(session)
            .injectAppTheme()
        }
        .confirmationDialog(
            "删除所选资产？",
            isPresented: $showingBulkDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除 \(selectedAssetIDs.count) 个资产", role: .destructive) {
                deleteSelectedServers()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除本地凭据并尝试同步云端删除。此操作不可撤销。")
        }
#if os(macOS)
        .frame(minWidth: 760, minHeight: 520)
#endif
    }

    private var filteredServers: [ServerEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.servers }
        return store.servers.filter { $0.matchesSearch(q) }
    }

    private var groupedFiltered: [(group: String, items: [ServerEntry])] {
        let grouped = Dictionary(grouping: filteredServers, by: { $0.displayGroup })
        return grouped.keys.sorted().map { key in
            (group: key, items: (grouped[key] ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
    }

    private func assetRow(for server: ServerEntry) -> some View {
        let actions = AssetManagerServerRowActions(
            connect: { onConnect(server) },
            edit: { onEdit(server) },
            keySetup: { keySetupServer = server },
            enablePasswordFallback: { enablePasswordFallback(server) },
            disablePasswordFallback: { Task { await disablePasswordFallback(server) } },
            delete: { deleteServer(server) }
        )
        return AssetManagerServerRow(
            server: server,
            isSelected: store.selectedServerID == server.id,
            actions: actions
        )
        .tag(server.id)
    }

    @ViewBuilder
    private var bottomStatusBar: some View {
        if !noticeText.isEmpty || !selectedAssetIDs.isEmpty {
            VStack(spacing: 0) {
                if !noticeText.isEmpty {
                    HStack(spacing: 8) {
                        if let changingID = policyChangingID,
                           filteredServers.contains(where: { $0.id == changingID }) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "info.circle.fill")
                        }
                        Text(noticeText)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .foregroundStyle(noticeKind.map { kind in security.presentation(for: kind).color.color } ?? palette.textSecondary.color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }

                if !selectedAssetIDs.isEmpty {
                    HStack(spacing: 10) {
                        Text("已选择 \(selectedAssetIDs.count) 个资产")
                            .font(.caption.weight(.medium))
                        Spacer(minLength: 0)
                        Button("取消选择") { selectedAssetIDs.removeAll() }
                            .buttonStyle(.borderless)
                        Button("删除所选", role: .destructive) {
                            showingBulkDeleteConfirmation = true
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(palette.surfaceInput.color)
                }
            }
            .background(palette.surfaceReadable.color)
            .overlay(alignment: .top) {
                Rectangle().fill(palette.divider.color).frame(height: 1)
            }
        }
    }

    private func enablePasswordFallback(_ server: ServerEntry) {
        var updated = server
        updated.allowPasswordFallback = true
        store.addOrUpdate(updated)
        syncServerUpdate(updated)
        noticeKind = .success
        noticeText = "已开启密码登录：\(server.name)"
    }

    private func deleteServer(_ server: ServerEntry) {
        store.remove(server)
        let token = session.readToken()
        let masterPassword = session.readMasterPassword()
        Task(priority: .background) {
            await syncService.deleteRemoteConfigs(
                for: [server], token: token, masterPassword: masterPassword, accountID: session.username
            )
        }
    }

    private func deleteSelectedServers() {
        let targets = store.servers.filter { selectedAssetIDs.contains($0.id) }
        guard !targets.isEmpty else {
            selectedAssetIDs.removeAll()
            return
        }

        store.removeMany(selectedAssetIDs)
        selectedAssetIDs.removeAll()
        noticeKind = .success
        noticeText = "已删除 \(targets.count) 个资产，正在同步云端删除"

        let token = session.readToken()
        let masterPassword = session.readMasterPassword()
        Task(priority: .background) {
            await syncService.deleteRemoteConfigs(
                for: targets,
                token: token,
                masterPassword: masterPassword,
                accountID: session.username
            )
        }
    }

    private func syncServerUpdate(_ server: ServerEntry) {
        guard let credentials = try? vault.read(for: server.credentialID),
              let token = session.readToken(),
              let masterPassword = session.readMasterPassword() else { return }
        let portable = server.makePortableConfig(savedAtUnix: Int(Date().timeIntervalSince1970), credentials: credentials)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(portable),
              let plain = String(data: data, encoding: .utf8) else { return }
        Task(priority: .background) {
            _ = await syncService.uploadEncryptedConfig(
                token: token,
                masterPassword: masterPassword,
                accountID: session.username,
                plaintextConfig: plain,
                vectorClock: ["client": Int(Date().timeIntervalSince1970)],
                allowQueueOnNetworkFailure: true
            )
        }
    }

    private func disablePasswordFallback(_ server: ServerEntry) async {
        guard policyChangingID == nil else { return }
        guard ConnectionSecurityPolicy.allowsLegacyConnectionTest else {
            noticeKind = .warning
            noticeText = "请通过已验证连接流程确认密钥后再关闭密码登录"
            return
        }
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        policyChangingID = server.id
        defer { policyChangingID = nil }
        guard let credentials = try? vault.read(for: server.credentialID),
              !credentials.privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            noticeKind = .warning
            noticeText = "关闭失败：请先为 \(server.name) 设置有效私钥并测试通过"
            return
        }

        let result = await orbitManager.testConnectionAsync(
            ip: server.host,
            port: server.port,
            username: server.username,
            password: "",
            privateKeyContent: credentials.privateKeyContent,
            privateKeyPassphrase: credentials.privateKeyPassphrase,
            allowPasswordFallback: false
        )

        guard result.hasPrefix("成功") else {
            noticeKind = .warning
            noticeText = "关闭失败：密钥登录测试未通过（\(result)）"
            return
        }

        var updated = server
        updated.allowPasswordFallback = false
        store.addOrUpdate(updated)
        syncServerUpdate(updated)
        noticeKind = .success
        noticeText = "已关闭密码登录（仅密钥模式）：\(server.name)"
        #endif
    }
}

private struct AssetManagerServerRowActions {
    let connect: () -> Void
    let edit: () -> Void
    let keySetup: () -> Void
    let enablePasswordFallback: () -> Void
    let disablePasswordFallback: () -> Void
    let delete: () -> Void
}

private struct AssetManagerCloseButton: View {
    @Environment(\.appThemePalette) private var palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("关闭")
                .font(.callout.weight(.semibold))
                .foregroundStyle(palette.textPrimary.color)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(palette.surfaceReadable.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(palette.borderGlass.color, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭资产管理")
    }
}

private struct AssetManagerServerRow: View {
    @Environment(\.appThemePalette) private var palette

    let server: ServerEntry
    let isSelected: Bool
    let actions: AssetManagerServerRowActions

    private var endpoint: String {
        "\(server.username)@\(server.host):\(server.port)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isSelected ? palette.accentPrimary.color : palette.borderGlass.color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.body.weight(.medium))
                Text(endpoint)
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
                if !server.tags.isEmpty {
                    Text(server.tags.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(palette.accentSecondary.color)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("连接", action: actions.connect)
                .frame(width: 68)
                .buttonStyle(ThemedPrimaryButtonStyle())
            Button("编辑", action: actions.edit)
                .frame(width: 68)
                .buttonStyle(ThemedSecondaryButtonStyle())
            Button("设密钥", action: actions.keySetup)
                .frame(width: 68)
                .buttonStyle(ThemedSecondaryButtonStyle())
        }
        .contextMenu {
            Button("连接", action: actions.connect)
            Button("编辑凭据", action: actions.edit)
            Button("一键设置密钥", action: actions.keySetup)
            if server.allowPasswordFallback {
                Button("关闭密码登录", action: actions.disablePasswordFallback)
            } else {
                Button("开启密码登录", action: actions.enablePasswordFallback)
            }
            Button("删除", role: .destructive, action: actions.delete)
        }
    }
}
