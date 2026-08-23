import SwiftUI

struct ServerListView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var store: ServerStore
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security
    @ObservedObject private var sessionManager = SessionManager.shared
    @EnvironmentObject private var syncService: SyncService
    @StateObject private var snippetStore = SnippetStore.shared
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
    @State private var showingBulkAdd = false
    @State private var isSynchronizing = false
    @State private var armedConnectionServerID: UUID?
    @State private var connectionArmTask: Task<Void, Never>?
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
                                            .foregroundStyle(selectedForDelete.contains(server.id) ? security.danger.color : palette.textSecondary.color)
                                    }
                                    Button {
                                        if batchMode {
                                            toggleBatchSelection(server.id)
                                        } else {
                                            handlePrimaryAssetTap(server)
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(server.name)
                                                if isServerConnected(server) {
                                                    Label("已连接", systemImage: "dot.radiowaves.left.and.right")
                                                        .font(.caption2.weight(.semibold))
                                                        .foregroundStyle(security.connectionConnected.color)
                                                }
                                            }
                                            Text("\(server.username)@\(server.endpointText)")
                                                .font(.caption)
                                                .foregroundStyle(palette.textSecondary.color)
                                            if armedConnectionServerID == server.id, !isServerConnected(server) {
                                                Label("再次点击以连接", systemImage: "hand.tap")
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(palette.accentPrimary.color)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityHint(
                                        batchMode
                                            ? "切换批量选择状态"
                                            : armedConnectionServerID == server.id
                                                ? "再次点击将建立远程连接"
                                                : "点击一次准备连接，再次点击确认；也可向右轻扫后选择连接"
                                    )
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
                                        .tint(palette.accentPrimary.color)

                                        Button(role: .destructive) {
                                            pendingDeleteServer = server
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        Button {
                                            connect(server)
                                        } label: {
                                            Label("连接", systemImage: "terminal.fill")
                                        }
                                        .tint(security.connectionConnected.color)
                                    }

                                    if !batchMode {
                                        Button {
                                            editingServer = server
                                        } label: {
                                            Image(systemName: "square.and.pencil")
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(palette.accentPrimary.color)
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
                                if batchMode {
                                    let groupIDs = Set(section.items.map(\.id))
                                    let selectedCount = groupIDs.intersection(selectedForDelete).count
                                    Button {
                                        if selectedCount == groupIDs.count {
                                            selectedForDelete.subtract(groupIDs)
                                        } else {
                                            selectedForDelete.formUnion(groupIDs)
                                        }
                                    } label: {
                                        Image(systemName: selectedCount == 0
                                            ? "square"
                                            : selectedCount == groupIDs.count
                                                ? "checkmark.square.fill"
                                                : "minus.square.fill")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(selectedCount == groupIDs.count ? "取消选择分组 \(section.group)" : "选择分组 \(section.group)")
                                }
                                Text(section.group)
                                Spacer()
                                Text("\(section.items.count)")
                                    .font(.caption)
                                    .foregroundStyle(palette.textSecondary.color)
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
        .scrollContentBackground(.hidden)
        .background(AppChromeBackground())
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索名称、IP、用户、分组或标签")
#else
        .listStyle(.inset)
        .searchable(text: $searchText, prompt: "搜索名称、IP、用户、分组或标签")
#endif
        .navigationTitle("服务器")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
#if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("批量添加资产") {
                        showingBulkAdd = true
                    }
                    if !store.servers.isEmpty {
                        Divider()
                        Button(batchMode ? "完成批量选择" : "批量选择") {
                            batchMode.toggle()
                            if !batchMode { selectedForDelete.removeAll() }
                        }
                    }
                } label: {
                    Label("批量", systemImage: "checklist")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    startImmediateSynchronization()
                } label: {
                    if isSynchronizing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isSynchronizing || !session.isUnlocked)
                .accessibilityLabel("立即双向同步")
                .accessibilityHint("同步资产、分组、标签、命令片段、SSH 密钥与端口映射配置")
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
        .sheet(isPresented: $showingBulkAdd) {
            BulkAddAssetsSheet(store: store) { _ in }
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
        .onDisappear {
            connectionArmTask?.cancel()
            connectionArmTask = nil
            armedConnectionServerID = nil
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

    private func startImmediateSynchronization() {
        guard !isSynchronizing else { return }
        guard let token = session.readToken(),
              let masterPassword = session.readMasterPassword() else {
            syncService.setSyncRecoveryPresentation(
                session.isAuthenticated
                    ? OperationRecoveryMapper.syncMasterPasswordUnavailable()
                    : OperationRecoveryMapper.syncTokenUnavailable()
            )
            return
        }
        isSynchronizing = true
        Task {
            defer { isSynchronizing = false }
            await syncService.reconcileAssetInventory(
                token: token,
                masterPassword: masterPassword,
                store: store,
                accountID: session.username
            )
            await snippetStore.pullFromCloud(
                token: token,
                masterPassword: masterPassword,
                accountID: session.username
            )
            await syncService.refreshInventoryDiagnostic(token: token, store: store)
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
        connectionArmTask?.cancel()
        connectionArmTask = nil
        armedConnectionServerID = nil
        store.select(server)
        sessionManager.quickOpenServer = server
        onConnectRequested?(server)
        session.showTransientStatus("已选择 \(server.name)，请在连接页发起连接")
    }

    private func handlePrimaryAssetTap(_ server: ServerEntry) {
        if isServerConnected(server) || armedConnectionServerID == server.id {
            connect(server)
            return
        }

        connectionArmTask?.cancel()
        armedConnectionServerID = server.id
        session.showTransientStatus("再次点击“\(server.name)”即可连接；也可向右轻扫后选择连接")
        connectionArmTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, armedConnectionServerID == server.id else { return }
            armedConnectionServerID = nil
            connectionArmTask = nil
        }
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
            await syncService.deleteRemoteConfigs(
                for: servers, token: token, masterPassword: masterPassword, accountID: session.username
            )
        }
    }

    private func isServerConnected(_ server: ServerEntry) -> Bool {
        sessionManager.tabs.contains(where: { $0.server.id == server.id && $0.isConnected })
    }

    private var filteredGroupedServers: [(group: String, items: [ServerEntry])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.groupedServers }

        let filtered = store.servers.filter { $0.matchesSearch(query) }
        let grouped = Dictionary(grouping: filtered, by: { $0.displayGroup })
        return grouped.keys.sorted().map { key in
            (group: key, items: grouped[key] ?? [])
        }
    }
}
