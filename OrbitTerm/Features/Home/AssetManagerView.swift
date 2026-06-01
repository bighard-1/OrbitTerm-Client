import SwiftUI

struct AssetManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession

    @ObservedObject var store: ServerStore
    let onEdit: (ServerEntry) -> Void
    let onConnect: (ServerEntry) -> Void

    @State private var query = ""
    @State private var noticeText: String = ""
    @State private var noticeColor: Color = .secondary
    @State private var policyChangingID: UUID?
    @State private var keySetupServer: ServerEntry?
    @State private var showingBulkAdd = false

    private let vault = CredentialVault.shared
    @StateObject private var orbitManager = OrbitManager()
    @StateObject private var syncService = SyncService.shared

    var body: some View {
        NavigationStack {
            List {
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
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(store.selectedServerID == server.id ? Color.green : Color.gray.opacity(0.35))
                                        .frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(server.name)
                                            .font(.body.weight(.medium))
                                        Text("\(server.username)@\(server.host):\(server.port)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("连接") { onConnect(server) }
                                        .buttonStyle(.borderedProminent)
                                    Button("编辑") { onEdit(server) }
                                        .buttonStyle(.bordered)
                                    Button("设密钥") { keySetupServer = server }
                                        .buttonStyle(.bordered)
                                }
                                .contextMenu {
                                    Button("连接") { onConnect(server) }
                                    Button("编辑凭据") { onEdit(server) }
                                    Button("一键设置密钥") { keySetupServer = server }
                                    if server.allowPasswordFallback {
                                        Button("关闭密码登录") {
                                            Task { await disablePasswordFallback(server) }
                                        }
                                    } else {
                                        Button("开启密码登录") {
                                            enablePasswordFallback(server)
                                        }
                                    }
                                    Button("删除", role: .destructive) {
                                        deleteServer(server)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "搜索名称 / 主机 / 用户名")
            .navigationTitle("资产管理")
            .safeAreaInset(edge: .bottom) {
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
                    .foregroundStyle(noticeColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingBulkAdd = true
                    } label: {
                        Label("批量添加", systemImage: "square.stack.3d.up.fill")
                    }
                }
            }
        }
        .sheet(item: $keySetupServer) { server in
            QuickKeySetupSheet(server: server, store: store) { status in
                switch status {
                case let .saved(message):
                    noticeColor = .green
                    noticeText = message
                case let .failed(message):
                    noticeColor = .orange
                    noticeText = message
                }
            }
        }
        .sheet(isPresented: $showingBulkAdd) {
            BulkAddAssetsSheet(store: store) { count in
                noticeColor = count > 0 ? .green : .orange
                noticeText = count > 0 ? "已批量添加 \(count) 个资产，并已进入后台同步" : "未添加资产，请检查输入格式"
            }
            .environmentObject(session)
        }
#if os(macOS)
        .frame(minWidth: 760, minHeight: 520)
#endif
    }

    private var filteredServers: [ServerEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.servers }
        return store.servers.filter { server in
            server.name.localizedCaseInsensitiveContains(q) ||
                server.host.localizedCaseInsensitiveContains(q) ||
                server.username.localizedCaseInsensitiveContains(q) ||
                server.group.localizedCaseInsensitiveContains(q)
        }
    }

    private var groupedFiltered: [(group: String, items: [ServerEntry])] {
        let grouped = Dictionary(grouping: filteredServers, by: { $0.displayGroup })
        return grouped.keys.sorted().map { key in
            (group: key, items: (grouped[key] ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
    }

    private func enablePasswordFallback(_ server: ServerEntry) {
        var updated = server
        updated.allowPasswordFallback = true
        store.addOrUpdate(updated)
        syncServerUpdate(updated)
        noticeColor = .green
        noticeText = "已开启密码登录：\(server.name)"
    }

    private func deleteServer(_ server: ServerEntry) {
        store.remove(server)
        let token = session.readToken()
        let masterPassword = session.readMasterPassword()
        Task(priority: .background) {
            await syncService.deleteRemoteConfigs(for: [server], token: token, masterPassword: masterPassword)
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
                plaintextConfig: plain,
                vectorClock: ["client": Int(Date().timeIntervalSince1970)],
                allowQueueOnNetworkFailure: true
            )
        }
    }

    private func disablePasswordFallback(_ server: ServerEntry) async {
        guard policyChangingID == nil else { return }
        policyChangingID = server.id
        defer { policyChangingID = nil }

        guard let credentials = try? vault.read(for: server.credentialID),
              !credentials.privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            noticeColor = .orange
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
            noticeColor = .orange
            noticeText = "关闭失败：密钥登录测试未通过（\(result)）"
            return
        }

        var updated = server
        updated.allowPasswordFallback = false
        store.addOrUpdate(updated)
        syncServerUpdate(updated)
        noticeColor = .green
        noticeText = "已关闭密码登录（仅密钥模式）：\(server.name)"
    }
}
