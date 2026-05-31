import SwiftUI

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
            let widths = WorkstationLayoutMetrics.widths(
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
    }

    private var leftColumn: some View {
        WorkstationAssetSidebarView(
            serverStore: serverStore,
            sessionManager: sessionManager,
            searchText: $leftSearchText,
            onCollapse: {
                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                    isLeftPanelCollapsed = true
                }
            },
            onAddServer: { showingAddServer = true },
            onEditServer: { server in editingServer = server },
            onOpenServer: { server in openServerSession(server) },
            onDeleteServer: { server in pendingDeleteServer = server }
        )
    }

    private func openServerSession(_ server: ServerEntry) {
        serverStore.select(server)
        sessionManager.quickOpenServer = server
        sessionManager.openTab(for: server, autoConnect: true)
    }

    private var collapsedLeftRail: some View {
        WorkstationLeftRailView {
            withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                isLeftPanelCollapsed = false
            }
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

}
