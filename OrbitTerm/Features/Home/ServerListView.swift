import SwiftUI

struct ServerListView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var store: ServerStore
    @ObservedObject private var sessionManager = SessionManager.shared
    @StateObject private var syncService = SyncService.shared
    @State private var showingAddServer = false
    @State private var expandedGroups: Set<String> = []
    @State private var selectedForDelete: Set<UUID> = []
    @State private var renamingGroup: String?
    @State private var groupRenameText: String = ""
    @State private var batchMode = false
    @State private var editingServer: ServerEntry?
    @State private var pendingDeleteServer: ServerEntry?
    @State private var pendingDeleteGroup: String?
    @State private var searchText = ""
    var onConnectRequested: ((ServerEntry) -> Void)?

    var body: some View {
        List {
            if filteredGroupedServers.isEmpty {
                ContentUnavailableView(
                    store.servers.isEmpty ? "还没有服务器" : "没有匹配的资产",
                    systemImage: store.servers.isEmpty ? "server.rack" : "magnifyingglass",
                    description: Text(store.servers.isEmpty ? "点击右上角 + 添加" : "换个关键词试试名称、IP、用户或分组")
                )
            } else {
                ForEach(filteredGroupedServers, id: \.group) { section in
                    Section {
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedGroups.contains(section.group) },
                                set: { expanded in
                                    if expanded { expandedGroups.insert(section.group) } else { expandedGroups.remove(section.group) }
                                }
                            )
                        ) {
                            ForEach(section.items) { server in
                                HStack(spacing: 8) {
                                    if batchMode {
                                        Image(systemName: selectedForDelete.contains(server.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedForDelete.contains(server.id) ? .red : .secondary)
                                    }
                                    Button {
                                        if batchMode {
                                            toggleBatchSelection(server.id)
                                        } else {
                                            connect(server)
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(server.name)
                                                if isServerConnected(server) {
                                                    Label("已连接", systemImage: "dot.radiowaves.left.and.right")
                                                        .font(.caption2.weight(.semibold))
                                                        .foregroundStyle(.green)
                                                }
                                            }
                                            Text("\(server.username)@\(server.endpointText)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("连接") {
                                            connect(server)
                                        }
                                        Button("编辑资产") {
                                            editingServer = server
                                        }
                                        Button("删除", role: .destructive) {
                                            pendingDeleteServer = server
                                        }
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button {
                                            editingServer = server
                                        } label: {
                                            Label("编辑", systemImage: "square.and.pencil")
                                        }
                                        .tint(.blue)

                                        Button(role: .destructive) {
                                            pendingDeleteServer = server
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }

                                    if !batchMode {
                                        Button {
                                            editingServer = server
                                        } label: {
                                            Image(systemName: "square.and.pencil")
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(.blue)
                                                .frame(width: 36, height: 36)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("编辑资产")
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(section.group)
                                Spacer()
                                Text("\(section.items.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Menu {
                                    Button("重命名分组") {
                                        renamingGroup = section.group
                                        groupRenameText = section.group == "未分组" ? "" : section.group
                                    }
                                    if section.group != "未分组" {
                                        Button("删除分组", role: .destructive) {
                                            pendingDeleteGroup = section.group
                                        }
                                    }
                                    Button("全部展开") { expandedGroups.insert(section.group) }
                                    Button("全部收起") { expandedGroups.remove(section.group) }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
#if os(iOS)
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索名称、IP、用户或分组")
#else
        .listStyle(.inset)
        .searchable(text: $searchText, prompt: "搜索名称、IP、用户或分组")
#endif
        .navigationTitle("服务器")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
#if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                if !store.servers.isEmpty {
                    Button(batchMode ? "完成" : "批量") {
                        batchMode.toggle()
                        if !batchMode { selectedForDelete.removeAll() }
                    }
                }
            }
#else
            ToolbarItem(placement: .automatic) {
                if !store.servers.isEmpty {
                    Button(batchMode ? "完成" : "批量") {
                        batchMode.toggle()
                        if !batchMode { selectedForDelete.removeAll() }
                    }
                }
            }
#endif
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddServer = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if batchMode && !selectedForDelete.isEmpty {
                    Button(role: .destructive) {
                        deleteSelectedServers()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .alert("重命名分组", isPresented: Binding(
            get: { renamingGroup != nil },
            set: { shown in if !shown { renamingGroup = nil } }
        )) {
            TextField("分组名称", text: $groupRenameText)
            Button("取消", role: .cancel) {}
            Button("保存") {
                guard let old = renamingGroup else { return }
                store.renameGroup(from: old, to: groupRenameText)
                renamingGroup = nil
            }
        } message: {
            Text("将当前分组内所有资产移动到新分组名")
        }
        .sheet(isPresented: $showingAddServer) {
            AddServerView(store: store) { _ in }
                .environmentObject(session)
        }
        .sheet(item: $editingServer) { server in
            AddServerView(store: store, editingServer: server) { updated in
                connect(updated)
            }
            .environmentObject(session)
        }
        .alert("确认删除资产", isPresented: Binding(
            get: { pendingDeleteServer != nil },
            set: { shown in
                if !shown { pendingDeleteServer = nil }
            }
        )) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                guard let target = pendingDeleteServer else { return }
                deleteServers([target])
                pendingDeleteServer = nil
            }
        } message: {
            if let server = pendingDeleteServer {
                Text("将删除资产“\(server.name)”，此操作不可撤销。")
            } else {
                Text("此操作不可撤销。")
            }
        }
        .alert("确认删除分组", isPresented: Binding(
            get: { pendingDeleteGroup != nil },
            set: { shown in
                if !shown { pendingDeleteGroup = nil }
            }
        )) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                guard let group = pendingDeleteGroup else { return }
                deleteGroup(group)
                pendingDeleteGroup = nil
            }
        } message: {
            if let group = pendingDeleteGroup {
                Text("将删除分组“\(group)”及其下全部资产。")
            } else {
                Text("此操作不可撤销。")
            }
        }
    }

    private func toggleBatchSelection(_ id: UUID) {
        if selectedForDelete.contains(id) {
            selectedForDelete.remove(id)
        } else {
            selectedForDelete.insert(id)
        }
    }

    private func connect(_ server: ServerEntry) {
        store.select(server)
        sessionManager.quickOpenServer = server
        onConnectRequested?(server)
        session.showTransientStatus("已选择 \(server.name)，请在连接页发起连接")
    }

    private func deleteSelectedServers() {
        let targets = store.servers.filter { selectedForDelete.contains($0.id) }
        store.removeMany(selectedForDelete)
        selectedForDelete.removeAll()
        syncDeletedServers(targets)
    }

    private func deleteServers(_ servers: [ServerEntry]) {
        for server in servers {
            store.remove(server)
        }
        syncDeletedServers(servers)
    }

    private func deleteGroup(_ group: String) {
        let targets = store.servers.filter { $0.displayGroup == group || $0.group == (group == "未分组" ? "" : group) }
        store.removeGroup(group)
        syncDeletedServers(targets)
    }

    private func syncDeletedServers(_ servers: [ServerEntry]) {
        guard !servers.isEmpty else { return }
        let token = session.readToken()
        let masterPassword = session.readMasterPassword()
        Task(priority: .background) {
            await syncService.deleteRemoteConfigs(for: servers, token: token, masterPassword: masterPassword)
        }
    }

    private func isServerConnected(_ server: ServerEntry) -> Bool {
        sessionManager.tabs.contains(where: { $0.server.id == server.id && $0.isConnected })
    }

    private var filteredGroupedServers: [(group: String, items: [ServerEntry])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.groupedServers }

        let lowered = query.lowercased()
        let filtered = store.servers.filter { server in
            [
                server.name,
                server.displayGroup,
                server.host,
                server.username,
                server.endpointText,
                server.transport.displayName
            ]
            .contains { $0.lowercased().contains(lowered) }
        }
        let grouped = Dictionary(grouping: filtered, by: { $0.displayGroup })
        return grouped.keys.sorted().map { key in
            (group: key, items: grouped[key] ?? [])
        }
    }
}
