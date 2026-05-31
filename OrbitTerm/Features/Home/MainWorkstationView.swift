import SwiftUI
import Charts
import UniformTypeIdentifiers

private enum MonitorHistoryRange: String, CaseIterable, Identifiable {
    case realtime = "实时"
    case min5 = "5 分钟"
    case min10 = "10 分钟"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .realtime: return 30
        case .min5: return 5 * 60
        case .min10: return 10 * 60
        }
    }
}

struct MainWorkstationView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var serverStore: ServerStore
    @Environment(\.openWindow) private var openWindow

    @ObservedObject private var sessionManager = SessionManager.shared
    @StateObject private var syncService = SyncService.shared
    @StateObject private var diagnostics = DiagnosticsManager.shared
    @StateObject private var snippetStore = SnippetStore.shared

    @State private var showingAddServer = false
    @State private var editingServer: ServerEntry?
    @State private var pendingDeleteServer: ServerEntry?
    @State private var showingAssetManager = false
    @State private var showingSettings = false
    @State private var showingDiagnostics = false
    @State private var showingBatchCommand = false
    @State private var leftSearchText = ""
    @State private var isLeftPanelCollapsed = false
    @State private var isRightPanelCollapsed = false
    @State private var showMonitorPanel = true
    @State private var showSFTPPanel = true
    @State private var showDockerPanel = true
    @State private var showSnippetsPanel = true
    @State private var isStressRunning = false
    @State private var stressTask: Task<Void, Never>?
    @State private var showingMonitorDetailPanelID: UUID?
    @State private var pendingSFTPRename: PendingSFTPRename?
    @State private var pendingSFTPRenameText: String = ""
    @State private var pendingSFTPCreate: PendingSFTPCreate?
    @State private var pendingSFTPCreateText: String = ""
    @State private var pendingSFTPChmod: PendingSFTPChmod?
    @State private var pendingSFTPChmodText: String = ""
    @State private var pendingSFTPFileEdit: PendingSFTPFileEdit?
    @State private var pendingSFTPFileEditContent: String = ""
    @State private var pendingSFTPFileEditStatus: String = ""
    @State private var pendingSFTPFileEditLoading = false
    @State private var pendingSFTPFileEditSaving = false

    var body: some View {
        GeometryReader { proxy in
            let widths = workstationWidths(
                totalWidth: proxy.size.width,
                leftCollapsed: isLeftPanelCollapsed,
                rightCollapsed: isRightPanelCollapsed
            )

            HStack(spacing: 0) {
                if isLeftPanelCollapsed {
                    collapsedLeftRail
                        .frame(width: widths.left)
                } else {
                    leftColumn
                        .frame(width: widths.left)
                }

                Divider()

                middleColumn
                    .frame(width: widths.middle)

                Divider()

                if isRightPanelCollapsed {
                    collapsedRail
                        .frame(width: widths.right)
                } else {
                    rightColumn
                        .frame(width: widths.right)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.85), value: isRightPanelCollapsed)
        }
        .navigationTitle("工作站")
        .toolbar {
#if DEBUG
            ToolbarItem(placement: .automatic) {
                DebugFPSBadge()
            }
#endif
            ToolbarItem(placement: .automatic) {
                if diagnostics.isRetrying {
                    ProgressView()
                        .controlSize(.small)
                        .help("网络重试中")
                }
            }
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 6) {
                    Image(systemName: syncService.lastSyncMessage.contains("失败") ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.icloud.fill")
                    Text(syncService.lastSyncMessage)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(syncService.lastSyncMessage.contains("失败") ? .orange : .secondary)
                .help(syncService.lastSyncMessage)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("添加服务器") { showingAddServer = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("编辑凭据") {
                    guard let selected = serverStore.selectedServer else { return }
                    editingServer = selected
                }
                .disabled(serverStore.selectedServer == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("资产管理") { showingAssetManager = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("批量命令") { showingBatchCommand = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("设置") { showingSettings = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("诊断") { showingDiagnostics = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("退出登录") { session.logout() }
            }
        }
        .sheet(isPresented: $showingAddServer) {
            AddServerView(store: serverStore) { server in
                serverStore.select(server)
                sessionManager.quickOpenServer = server
                sessionManager.openTab(for: server, autoConnect: true)
            }
            .environmentObject(session)
#if os(macOS)
            .frame(minWidth: 500, minHeight: 650)
#endif
        }
        .sheet(item: $editingServer) { server in
            AddServerView(store: serverStore, editingServer: server) { updated in
                serverStore.select(updated)
                sessionManager.quickOpenServer = updated
                sessionManager.openTab(for: updated, autoConnect: true)
            }
            .environmentObject(session)
#if os(macOS)
            .frame(minWidth: 500, minHeight: 650)
#endif
        }
        .sheet(isPresented: $showingAssetManager) {
            AssetManagerView(
                store: serverStore,
                onEdit: { server in editingServer = server },
                onConnect: { server in
                    serverStore.select(server)
                    sessionManager.openTab(for: server, autoConnect: true)
                }
            )
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
#if os(macOS)
                .frame(minWidth: 520, minHeight: 480)
#endif
        }
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsExportView()
#if os(macOS)
                .frame(minWidth: 620, minHeight: 520)
#endif
        }
        .sheet(isPresented: $showingBatchCommand) {
            BatchCommandRunnerView(store: serverStore)
#if os(macOS)
                .frame(minWidth: 980, minHeight: 680)
#endif
        }
        .overlay(alignment: .bottom) {
            if !session.transientStatus.isEmpty {
                Text(session.transientStatus)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onDisappear {
            stopStressTest()
        }
        .modifier(WorkstationSFTPDialogs(
            sessionManager: sessionManager,
            pendingRename: $pendingSFTPRename,
            renameText: $pendingSFTPRenameText,
            pendingCreate: $pendingSFTPCreate,
            createText: $pendingSFTPCreateText,
            pendingChmod: $pendingSFTPChmod,
            chmodText: $pendingSFTPChmodText,
            pendingFileEdit: $pendingSFTPFileEdit,
            fileEditContent: $pendingSFTPFileEditContent,
            fileEditStatus: $pendingSFTPFileEditStatus,
            fileEditLoading: $pendingSFTPFileEditLoading,
            fileEditSaving: $pendingSFTPFileEditSaving,
            onLoadFileEdit: { edit in
                await loadSFTPFileForEdit(edit)
            },
            onSaveFileEdit: {
                await saveSFTPFileEdit()
            }
        ))
        .alert("确认删除资产", isPresented: Binding(
            get: { pendingDeleteServer != nil },
            set: { if !$0 { pendingDeleteServer = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDeleteServer = nil }
            Button("删除", role: .destructive) {
                guard let server = pendingDeleteServer else { return }
                pendingDeleteServer = nil
                deleteServer(server)
            }
        } message: {
            Text("将删除“\(pendingDeleteServer?.name ?? "该资产")”的本地记录，并尝试同步云端删除。此操作不可撤销。")
        }
        .sheet(item: $pendingSFTPFileEdit) { edit in
            NavigationStack {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(edit.item.name)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer()
                        if pendingSFTPFileEditLoading || pendingSFTPFileEditSaving {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    if !pendingSFTPFileEditStatus.isEmpty {
                        Text(pendingSFTPFileEditStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextEditor(text: $pendingSFTPFileEditContent)
                        .font(.system(.body, design: .monospaced))
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    HStack {
                        Button("关闭") {
                            pendingSFTPFileEdit = nil
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button("保存") {
                            Task { await saveSFTPFileEdit() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pendingSFTPFileEditLoading || pendingSFTPFileEditSaving)
                    }
                }
                .padding(14)
                .navigationTitle("在线编辑")
                .task(id: edit.id) {
                    await loadSFTPFileForEdit(edit)
                }
            }
#if os(macOS)
            .frame(minWidth: 700, minHeight: 520)
#endif
        }
    }

    private var leftColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text("服务器")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                        isLeftPanelCollapsed = true
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.borderless)
                Button {
                    showingAddServer = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if serverStore.servers.isEmpty {
                ContentUnavailableView(
                    "还没有服务器",
                    systemImage: "server.rack",
                    description: Text("点击右上角“添加服务器”开始")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextField("搜索名称、IP、用户或分组", text: $leftSearchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)

                List {
                    ForEach(filteredGroupedServers, id: \.group) { section in
                        Section(section.group) {
                            ForEach(section.items) { server in
                                Button {
                                    serverStore.select(server)
                                    sessionManager.quickOpenServer = server
                                } label: {
                                    HStack(spacing: 8) {
                                        ServerConnectionBadge(session: sessionForServer(server))
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 5) {
                                                Text(server.name)
                                                    .lineLimit(1)
                                                Text(server.transport.displayName)
                                                    .font(.caption2.weight(.semibold))
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(.thinMaterial, in: Capsule())
                                                    .foregroundStyle(.secondary)
                                            }
                                            HStack(spacing: 6) {
                                                Text(server.endpointText)
                                                    .lineLimit(1)
                                                ServerConnectionText(session: sessionForServer(server))
                                            }
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(serverStore.selectedServerID == server.id ? Color.accentColor.opacity(0.13) : Color.clear)
                                )
                                .simultaneousGesture(
                                    TapGesture(count: 2).onEnded {
                                        openServerSession(server)
                                    }
                                )
                                .contextMenu {
                                    Button("新建会话") {
                                        openServerSession(server)
                                    }
                                    Button("编辑凭据") {
                                        serverStore.select(server)
                                        editingServer = server
                                    }
                                    Button("删除", role: .destructive) { pendingDeleteServer = server }
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func sessionForServer(_ server: ServerEntry) -> WorkspaceSession? {
        sessionManager.tabs.first { $0.server.id == server.id }
    }

    private func openServerSession(_ server: ServerEntry) {
        serverStore.select(server)
        sessionManager.quickOpenServer = server
        sessionManager.openTab(for: server, autoConnect: true)
    }

    private var filteredGroupedServers: [(group: String, items: [ServerEntry])] {
        let query = leftSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return serverStore.groupedServers }

        let lowered = query.lowercased()
        let filtered = serverStore.servers.filter { server in
            server.name.lowercased().contains(lowered) ||
            server.host.lowercased().contains(lowered) ||
            server.username.lowercased().contains(lowered) ||
            server.displayGroup.lowercased().contains(lowered) ||
            server.endpointText.lowercased().contains(lowered)
        }
        let grouped = Dictionary(grouping: filtered, by: { $0.displayGroup })
        return grouped
            .map { group, items in
                (
                    group: group,
                    items: items.sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                )
            }
            .sorted {
                $0.group.localizedCaseInsensitiveCompare($1.group) == .orderedAscending
            }
    }

    private var collapsedLeftRail: some View {
        VStack {
            Button {
                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                    isLeftPanelCollapsed = false
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .rotationEffect(.degrees(180))
            }
            .buttonStyle(.borderless)
            .padding(.top, 12)
            Spacer()
        }
    }

    private var middleColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            TabBarView(
                tabs: sessionManager.tabs,
                activeTabID: sessionManager.activeTabID,
                onSelect: { tab in sessionManager.activateTab(tab.id) },
                onClose: { tab in sessionManager.closeTab(tab) },
                onNew: {
                    if let selected = serverStore.selectedServer {
                        sessionManager.quickOpenServer = selected
                    }
                    sessionManager.openQuickTabFromSelection()
                },
                onDetach: { tab in
                    openWindow(value: tab.id)
                }
            )

            Divider()

            if let active = sessionManager.activeSession {
                TerminalSessionPane(
                    session: active,
                    sessionManager: sessionManager,
                    isStressRunning: $isStressRunning,
                    onSplitStateChanged: { isSplitEnabled in
                        if isSplitEnabled {
                            showSFTPPanel = false
                        } else {
                            showSFTPPanel = true
                        }
                    },
                    onToggleStress: { target in
                        toggleStressTest(for: target)
                    }
                )
                .padding(12)
            } else {
                ContentUnavailableView(
                    "暂无会话",
                    systemImage: "terminal",
                    description: Text("从左侧选择服务器并点击 + 打开新标签")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("监控 + SFTP")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                        isRightPanelCollapsed = true
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    if let active = sessionManager.activeSession {
                        if showMonitorPanel {
                            WorkstationMonitorCardView(
                                active: active,
                                monitorService: sessionManager.monitorService,
                                isDetailShown: showingMonitorDetailPanelID == active.activeMonitorPanelID,
                                onHide: { showMonitorPanel = false },
                                onShowDetail: {
                                    if let panelID = active.activeMonitorPanelID {
                                        showingMonitorDetailPanelID = panelID
                                    }
                                },
                                onHideDetail: { showingMonitorDetailPanelID = nil }
                            )
                            if let panelID = showingMonitorDetailPanelID,
                               panelID == active.activeMonitorPanelID {
                                MonitorDetailInlineView(
                                    panelID: panelID,
                                    service: sessionManager.monitorService,
                                    onClose: { showingMonitorDetailPanelID = nil }
                                )
                            }
                        } else {
                            WorkstationCollapsedFeatureRow(title: "系统监控") { showMonitorPanel = true }
                        }

                        if active.terminalSplitCount > 0 {
                            WorkstationCollapsedFeatureRow(title: "SFTP（分屏模式已禁用同步）") { }
                        } else if showSFTPPanel {
                            WorkstationSFTPCardView(
                                active: active,
                                onHide: { showSFTPPanel = false },
                                onRefresh: {
                                    Task { try? await active.sftpManager.refresh() }
                                },
                                onCreateDirectory: {
                                    pendingSFTPCreate = PendingSFTPCreate(sessionID: active.id, kind: .directory)
                                    pendingSFTPCreateText = ""
                                },
                                onCreateFile: {
                                    pendingSFTPCreate = PendingSFTPCreate(sessionID: active.id, kind: .file)
                                    pendingSFTPCreateText = ""
                                },
                                onUp: {
                                    Task {
                                        let current = active.sftpManager.currentPath
                                        let parent: String
                                        if current == "/" {
                                            parent = "/"
                                        } else {
                                            let deletingLast = (current as NSString).deletingLastPathComponent
                                            parent = deletingLast.isEmpty ? "/" : deletingLast
                                        }
                                        await active.sftpManager.goToPath(parent)
                                        await sessionManager.syncTerminalPathFromSFTP(session: active, newPath: active.sftpManager.currentPath)
                                    }
                                },
                                onEnterDirectory: { item in
                                    Task {
                                        await active.sftpManager.enterDirectory(item)
                                        await sessionManager.syncTerminalPathFromSFTP(session: active, newPath: active.sftpManager.currentPath)
                                    }
                                },
                                onOpenFile: { item in
                                    openSFTPFileEditor(sessionID: active.id, item: item)
                                },
                                onDownload: { item in
                                    Task {
                                        let dst = desktopURL(fileName: item.name)
                                        await active.sftpManager.download(item: item, to: dst)
                                    }
                                },
                                onRename: { item in
                                    pendingSFTPRename = PendingSFTPRename(sessionID: active.id, item: item)
                                    pendingSFTPRenameText = item.name
                                },
                                onChmod: { item in
                                    pendingSFTPChmod = PendingSFTPChmod(sessionID: active.id, item: item)
                                    pendingSFTPChmodText = String(format: "%o", item.permissionsOctal & 0o7777)
                                },
                                onSetMode: { item, mode in
                                    Task { await active.sftpManager.chmod(item: item, modeOctal: mode) }
                                },
                                onDelete: { item in
                                    Task { await active.sftpManager.delete(item: item) }
                                }
                            )
                        } else {
                            WorkstationCollapsedFeatureRow(title: "SFTP") { showSFTPPanel = true }
                        }

                        if showDockerPanel {
                            WorkstationDockerCardView(active: active) {
                                showDockerPanel = false
                            }
                        } else {
                            WorkstationCollapsedFeatureRow(title: "Docker") { showDockerPanel = true }
                        }

                        if showSnippetsPanel {
                            WorkstationSnippetsCardView(
                                active: active,
                                snippetStore: snippetStore,
                                onHide: { showSnippetsPanel = false },
                                onInsertCommand: { command, executeImmediately in
                                    Task {
                                        await sessionManager.dispatchSnippetCommand(
                                            session: active,
                                            command: command,
                                            executeImmediately: executeImmediately
                                        )
                                    }
                                }
                            )
                        } else {
                            WorkstationCollapsedFeatureRow(title: "Snippets") { showSnippetsPanel = true }
                        }
                    } else {
                        Text("连接终端后自动展示监控与 SFTP")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(.regularMaterial)
    }

    private var collapsedRail: some View {
        WorkstationRightRailView {
            withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                isRightPanelCollapsed = false
            }
        }
    }

    private func desktopURL(fileName: String) -> URL {
#if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
#else
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return docs.appendingPathComponent(fileName, isDirectory: false)
#endif
    }

    private func deleteServer(_ server: ServerEntry) {
        serverStore.remove(server)
        let token = session.readToken()
        let masterPassword = session.readMasterPassword()
        Task(priority: .background) {
            await syncService.deleteRemoteConfigs(for: [server], token: token, masterPassword: masterPassword)
        }
    }

    private func openSFTPFileEditor(sessionID: UUID, item: FileItem) {
        pendingSFTPFileEdit = PendingSFTPFileEdit(sessionID: sessionID, item: item)
        pendingSFTPFileEditContent = ""
        pendingSFTPFileEditStatus = "正在读取文件..."
        pendingSFTPFileEditLoading = true
    }

    private func loadSFTPFileForEdit(_ edit: PendingSFTPFileEdit) async {
        guard let session = sessionManager.session(for: edit.sessionID) else {
            pendingSFTPFileEditStatus = "读取失败：会话不存在"
            pendingSFTPFileEditLoading = false
            return
        }

        pendingSFTPFileEditLoading = true
        defer { pendingSFTPFileEditLoading = false }
        do {
            let text = try await session.sftpManager.readTextFile(item: edit.item)
            pendingSFTPFileEditContent = text
            pendingSFTPFileEditStatus = "读取成功"
        } catch {
            pendingSFTPFileEditStatus = "读取失败：\(error.localizedDescription)"
        }
    }

    private func saveSFTPFileEdit() async {
        guard let edit = pendingSFTPFileEdit,
              let session = sessionManager.session(for: edit.sessionID) else {
            pendingSFTPFileEditStatus = "保存失败：会话不存在"
            return
        }
        pendingSFTPFileEditSaving = true
        defer { pendingSFTPFileEditSaving = false }
        do {
            try await session.sftpManager.writeTextFile(item: edit.item, content: pendingSFTPFileEditContent)
            pendingSFTPFileEditStatus = "保存成功"
        } catch {
            pendingSFTPFileEditStatus = "保存失败：\(error.localizedDescription)"
        }
    }

    private func toggleStressTest(for active: WorkspaceSession) {
        if isStressRunning {
            stopStressTest()
            active.appendTerminal("[stress] 压测已停止")
            return
        }

        isStressRunning = true
        active.appendTerminal("[stress] 开始 yes 字符流压测")

        let targetID = active.id
        stressTask = Task.detached(priority: .utility) {
            var lineNo = 0
            while !Task.isCancelled {
                lineNo += 1
                let line = "yes yes yes yes | chunk \(lineNo)"
                await MainActor.run {
                    if let session = SessionManager.shared.session(for: targetID) {
                        session.appendTerminal(line)
                    }
                }
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }
    }

    private func stopStressTest() {
        stressTask?.cancel()
        stressTask = nil
        isStressRunning = false
    }

    private func workstationWidths(
        totalWidth: CGFloat,
        leftCollapsed: Bool,
        rightCollapsed: Bool
    ) -> (left: CGFloat, middle: CGFloat, right: CGFloat) {
        let dividerSpace: CGFloat = 2
        let available = max(0, totalWidth - dividerSpace)
        let leftRail: CGFloat = 34
        let rightRail: CGFloat = 34

        var left = leftCollapsed ? leftRail : min(max(220, available * 0.20), 320)
        var right = rightCollapsed ? rightRail : min(max(260, available * 0.30), 420)
        let minMiddle: CGFloat = 420

        // Keep the terminal usable on narrower macOS windows by shrinking side panels
        // before the center workspace is allowed to overflow.
        let sideMinimum = (leftCollapsed ? leftRail : 200) + (rightCollapsed ? rightRail : 220)
        let targetMiddle = min(minMiddle, max(0, available - sideMinimum))
        let overflow = max(0, left + right + targetMiddle - available)
        if overflow > 0 {
            let rightFloor = rightCollapsed ? rightRail : 220
            let rightShrink = min(overflow, max(0, right - rightFloor))
            right -= rightShrink

            let remainingOverflow = overflow - rightShrink
            let leftFloor = leftCollapsed ? leftRail : 200
            let leftShrink = min(remainingOverflow, max(0, left - leftFloor))
            left -= leftShrink
        }

        let middle = max(0, available - left - right)
        return (left, middle, right)
    }
}

private struct ServerConnectionBadge: View {
    let session: WorkspaceSession?

    var body: some View {
        if let session {
            ObservedServerConnectionBadge(session: session)
        } else {
            Circle()
                .fill(Color.gray.opacity(0.35))
                .frame(width: 8, height: 8)
        }
    }
}

private struct ObservedServerConnectionBadge: View {
    @ObservedObject var session: WorkspaceSession

    var body: some View {
        Circle()
            .fill(session.isConnected ? Color.green : Color.orange.opacity(0.75))
            .frame(width: 8, height: 8)
            .shadow(color: session.isConnected ? .green.opacity(0.45) : .clear, radius: 4)
    }
}

private struct ServerConnectionText: View {
    let session: WorkspaceSession?

    var body: some View {
        if let session {
            ObservedServerConnectionText(session: session)
        } else {
            Text("未连接")
        }
    }
}

private struct ObservedServerConnectionText: View {
    @ObservedObject var session: WorkspaceSession

    var body: some View {
        Text(session.isConnected ? "已连接" : session.terminalStatus)
            .foregroundStyle(session.isConnected ? .green : .secondary)
    }
}

private struct TerminalDropToast: Identifiable {
    let id = UUID()
    let message: String
    let progress: Double?
    let isError: Bool
}

private struct TerminalSessionPane: View {
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var sessionManager: SessionManager
    @Binding var isStressRunning: Bool
    let onSplitStateChanged: (Bool) -> Void
    let onToggleStress: (WorkspaceSession) -> Void
    @State private var isDropTargeted = false
    @State private var uploadToast: TerminalDropToast?
    @State private var showSearchOverlay = false
    @State private var searchText = ""
    @State private var searchCommand: TerminalSearchCommand?
    @State private var searchStatusText = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("终端会话")
                    .font(.headline)
                Spacer()
#if os(macOS)
                Button("分屏 +") {
                    Task { @MainActor in
                        session.terminalSplitCount = min(3, session.terminalSplitCount + 1)
                        onSplitStateChanged(session.terminalSplitCount > 0)
                        await sessionManager.ensureTerminalSplitChannels(session: session)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(session.terminalSplitCount >= 3)

                Button("合并 -") {
                    Task { @MainActor in
                        session.terminalSplitCount = max(0, session.terminalSplitCount - 1)
                        onSplitStateChanged(session.terminalSplitCount > 0)
                        await sessionManager.ensureTerminalSplitChannels(session: session)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(session.terminalSplitCount <= 0)
#endif

                Button("测试连接") {
                    Task { await sessionManager.testConnection(session: session) }
                }

                Button("连接") {
                    Task { await sessionManager.connect(session: session) }
                }
                .buttonStyle(.borderedProminent)

                Button("Ctrl+C") {
                    Task { await sessionManager.sendCtrlC(session: session) }
                }
                .buttonStyle(.bordered)

                Button(isStressRunning ? "停止压测" : "yes 压测") {
                    onToggleStress(session)
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(session.server.name)
                    .font(.title3.weight(.semibold))
                Text("\(session.server.username)@\(session.server.endpointText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if showSearchOverlay {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索终端历史", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSearchFocused)
                        .onSubmit { triggerSearch(.next) }

                    Button {
                        triggerSearch(.previous)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        triggerSearch(.next)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        searchText = ""
                        triggerSearch(.clear)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.bordered)

                    Button("关闭") {
                        showSearchOverlay = false
                        searchStatusText = ""
                    }
                    .buttonStyle(.bordered)
                }

                if !searchStatusText.isEmpty {
                    Text(searchStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            terminalSplitLayout
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Color.blue.opacity(0.72) : Color.secondary.opacity(0.12),
                        style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: isDropTargeted ? [7, 5] : [])
                    )
            )
            .overlay(alignment: .bottomTrailing) {
                if let toast = uploadToast {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "arrow.up.circle.fill")
                                .foregroundStyle(toast.isError ? .orange : .blue)
                            Text(toast.message)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        if let progress = toast.progress {
                            ProgressView(value: progress)
                                .frame(width: 180)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
                    )
                    .padding(10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isDropTargeted)
            .onAppear {
                Task {
                    onSplitStateChanged(session.terminalSplitCount > 0)
                    await sessionManager.ensureTerminalSplitChannels(session: session)
                    await sessionManager.resizeTerminal(session: session, cols: 120, rows: 36)
                }
            }
            .overlay(alignment: .topLeading) {
#if os(macOS)
                Button("") {
                    showSearchOverlay = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isSearchFocused = true
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0.001)
                .frame(width: 1, height: 1)
#endif
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleTerminalDrop(providers: providers)
            }

            Text("状态：\(session.terminalStatus)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func triggerSearch(_ action: TerminalSearchAction) {
        searchCommand = TerminalSearchCommand(action: action)
    }

    private func handleTerminalDrop(providers: [NSItemProvider]) -> Bool {
        guard session.isConnected, session.sftpManager.isConnected, !session.sftpManager.isUsingMockData else {
            return false
        }
        let accepted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !accepted.isEmpty else { return false }

        for provider in accepted {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = resolveDropURL(item: item) else { return }
                Task { @MainActor in
                    await uploadDroppedFile(url)
                }
            }
        }
        return true
    }

    private func resolveDropURL(item: NSSecureCoding?) -> URL? {
        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
            return url
        }
        if let url = item as? URL {
            return url
        }
        if let str = item as? String, let url = URL(string: str), url.isFileURL {
            return url
        }
        return nil
    }

    @MainActor
    private func uploadDroppedFile(_ localURL: URL) async {
        guard session.isConnected, session.sftpManager.isConnected, !session.sftpManager.isUsingMockData else {
            return
        }

        let remotePath = remoteUploadPath(fileName: localURL.lastPathComponent)
        withAnimation(.easeInOut(duration: 0.18)) {
            uploadToast = TerminalDropToast(message: "正在上传 \(localURL.lastPathComponent)", progress: 0, isError: false)
        }

        await session.sftpManager.upload(localURL: localURL, remotePath: remotePath) { progress in
            Task { @MainActor in
                uploadToast = TerminalDropToast(message: "正在上传 \(localURL.lastPathComponent)", progress: progress, isError: false)
            }
        }

        let latestTask = session.sftpManager.transfers.first(where: {
            $0.fileName == localURL.lastPathComponent && $0.direction == .upload
        })
        let failed = latestTask?.statusText.contains("失败") ?? false

        if failed {
            withAnimation(.easeInOut(duration: 0.18)) {
                uploadToast = TerminalDropToast(message: latestTask?.statusText ?? "上传失败", progress: 1, isError: true)
            }
            dismissUploadToastLater()
            return
        }

        let pathLiteral = shellPathLiteral(remotePath)
        await sessionManager.sendTerminalBytes(session: session, bytes: Array(pathLiteral.utf8))
        withAnimation(.easeInOut(duration: 0.18)) {
            uploadToast = TerminalDropToast(message: "上传完成，已写入路径", progress: 1, isError: false)
        }
        dismissUploadToastLater()
    }

    private func remoteUploadPath(fileName: String) -> String {
        let current = session.sftpManager.currentPath
        if current == "/" { return "/\(fileName)" }
        return "\(current)/\(fileName)"
    }

    private func shellPathLiteral(_ path: String) -> String {
        if path.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
           !path.contains("'"),
           !path.contains("\"") {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func dismissUploadToastLater() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                uploadToast = nil
            }
        }
    }

    @ViewBuilder
    private var terminalSplitLayout: some View {
        #if os(macOS)
        switch session.terminalSplitCount {
        case 0:
            terminalPane(index: 0)
        case 1:
            VStack(spacing: 8) {
                terminalPane(index: 0)
                terminalPane(index: 1)
            }
        case 2:
            VStack(spacing: 8) {
                terminalPane(index: 0)
                HStack(spacing: 8) {
                    terminalPane(index: 1)
                    terminalPane(index: 2)
                }
            }
        default:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    terminalPane(index: 0)
                    terminalPane(index: 1)
                }
                HStack(spacing: 8) {
                    terminalPane(index: 2)
                    terminalPane(index: 3)
                }
            }
        }
        #else
        terminalPane(index: 0)
        #endif
    }

    private func terminalPane(index: Int) -> some View {
        let paneChannelID = paneChannel(for: index)
        return SwiftTermTerminalView(
            channelID: paneChannelID,
            onResize: { cols, rows in
                guard let paneChannelID else { return }
                Task { await sessionManager.resizeTerminal(session: session, cols: cols, rows: rows, channelID: paneChannelID) }
            },
            onInput: { bytes in
                guard let paneChannelID else { return }
                Task { @MainActor in
                    session.activeTerminalPaneIndex = index
                    await sessionManager.sendTerminalBytes(session: session, bytes: bytes, channelID: paneChannelID)
                }
            },
            searchText: searchText,
            searchCommand: searchCommand,
            onSearchFeedback: { found, action in
                switch action {
                case .clear:
                    searchStatusText = "已清除搜索高亮"
                case .next, .previous:
                    searchStatusText = found ? "已定位匹配项" : "未找到匹配项"
                }
            }
        )
        .id("terminal-pane-\(session.id.uuidString)-\(index)-\(paneChannelID ?? 0)")
        .onTapGesture {
            session.activeTerminalPaneIndex = index
        }
        .overlay(alignment: .topTrailing) {
            #if os(macOS)
            Text("分屏 \(index + 1)\(session.activeTerminalPaneIndex == index ? " · 当前" : "")")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(6)
            #endif
        }
    }

    private func paneChannel(for index: Int) -> UInt64? {
        if index < session.terminalChannelIDs.count {
            return session.terminalChannelIDs[index]
        }
        if index == 0 {
            return session.terminalChannelID
        }
        return nil
    }
}

private struct MonitorDetailInlineView: View {
    let panelID: UUID
    @ObservedObject var service: MonitorService
    let onClose: () -> Void
    @State private var range: MonitorHistoryRange = .min10

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("详细监控")
                    .font(.headline)
                Spacer()
                Picker("历史", selection: $range) {
                    ForEach(MonitorHistoryRange.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                Button("关闭") { onClose() }
                    .buttonStyle(.bordered)
            }

            if let panel = service.panel(id: panelID) {
                Text(panel.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                chartCard(title: "CPU", points: filtered(panel.points), value: \.cpuUsage, tint: .blue, domain: 0...100, percent: true)
                chartCard(title: "内存", points: filtered(panel.points), value: \.memUsedPercent, tint: .green, domain: 0...100, percent: true)
                chartCard(title: "磁盘", points: filtered(panel.points), value: \.diskUsedPercent, tint: .orange, domain: 0...100, percent: true)
                chartCard(title: "延迟", points: filtered(panel.points), value: { $0.pingLatencyMs ?? 0 }, tint: .purple, domain: 0...300, percent: false)
                chartCard(title: "下载速率", points: filtered(panel.points), value: \.rxRateKBps, tint: .cyan, domain: 0...rateUpperBound(filtered(panel.points), keyPath: \.rxRateKBps), percent: false, unit: "KB/s")
                chartCard(title: "上传速率", points: filtered(panel.points), value: \.txRateKBps, tint: .mint, domain: 0...rateUpperBound(filtered(panel.points), keyPath: \.txRateKBps), percent: false, unit: "KB/s")
            } else {
                ContentUnavailableView("暂无监控数据", systemImage: "chart.line.uptrend.xyaxis")
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func filtered(_ points: [MonitorPoint]) -> [MonitorPoint] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        return points.filter { $0.time >= cutoff }
    }

    private func chartCard(
        title: String,
        points: [MonitorPoint],
        value: @escaping (MonitorPoint) -> Double,
        tint: Color,
        domain: ClosedRange<Double>,
        percent: Bool,
        unit: String = "ms"
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let latest = points.last {
                Text(percent ? String(format: "%.1f%%", value(latest)) : String(format: "%.1f %@", value(latest), unit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Chart(points) { point in
                LineMark(
                    x: .value("时间", point.time),
                    y: .value("值", value(point))
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(tint)
            }
            .chartYScale(domain: domain)
            .frame(height: 120)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func rateUpperBound(_ points: [MonitorPoint], keyPath: KeyPath<MonitorPoint, Double>) -> Double {
        let maxValue = points.map { $0[keyPath: keyPath] }.max() ?? 100
        return max(100, ceil(maxValue * 1.25))
    }
}


#if DEBUG
private struct DebugFPSBadge: View {
    @StateObject private var meter = DebugFPSMeter()

    var body: some View {
        Text(String(format: "FPS %.0f", meter.fps))
            .font(.caption.monospacedDigit())
            .foregroundStyle(meter.fps >= 50 ? Color.secondary : (meter.fps >= 30 ? Color.orange : Color.red))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .help("渲染帧率采样（Debug）")
            .onAppear { meter.start() }
            .onDisappear { meter.stop() }
    }
}

private final class DebugFPSMeter: ObservableObject {
    @Published var fps: Double = 0
    private var timer: Timer?
    private var frameCount = 0
    private var lastSample = Date()

    func start() {
        guard timer == nil else { return }
        lastSample = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.frameCount += 1
                let now = Date()
                let elapsed = now.timeIntervalSince(self.lastSample)
                guard elapsed >= 1 else { return }
                self.fps = Double(self.frameCount) / elapsed
                self.frameCount = 0
                self.lastSample = now
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
#endif
