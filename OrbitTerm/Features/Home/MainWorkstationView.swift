import SwiftUI
#if os(macOS)
import AppKit
#endif

struct MainWorkstationView: View {
    @Environment(\.appThemePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var serverStore: ServerStore
    #if os(macOS)
    @EnvironmentObject private var shortcutCoordinator: WorkstationShortcutCoordinator
    @EnvironmentObject private var shortcutPreferences: WorkstationShortcutPreferences
    #endif
    @Environment(\.openWindow) private var openWindow

    @ObservedObject private var sessionManager = SessionManager.shared
    @EnvironmentObject private var syncService: SyncService
    @EnvironmentObject private var diagnostics: DiagnosticsManager
    @StateObject private var snippetStore = SnippetStore.shared

    @State private var showingAddServer = false
    @State private var editingServer: ServerEntry?
    @State private var pendingDeleteServer: ServerEntry?
    @State private var showingAssetManager = false
    @State private var showingSettings = false
    @State private var showingAccountSecurity = false
    @State private var showingBatchCommand = false
    @State private var showingKeyManagement = false
    @State private var showingPortForwarding = false
    @State private var leftSearchText = ""
    // The workstation sidebars open by default. Individual asset groups own
    // their own collapsed state in WorkstationAssetSidebarView.
    @State private var isLeftPanelCollapsed = false
    @State private var isRightPanelCollapsed = false
    @State private var isTerminalFullscreen = false
    @AppStorage("orbitterm.workstation.left.width") private var preferredLeftPanelWidth: Double = 260
    @AppStorage("orbitterm.workstation.right.width") private var preferredRightPanelWidth: Double = 340
    @State private var leftResizeOrigin: CGFloat?
    @State private var rightResizeOrigin: CGFloat?
    @State private var selectedRightPanelTab: WorkstationRightPanelTab = .sftp
    @State private var showingMonitorDetailPanelID: UUID?
    @State private var pendingSFTPRename: PendingSFTPRename?
    @State private var pendingSFTPRenameText: String = ""
    @State private var pendingSFTPCreate: PendingSFTPCreate?
    @State private var pendingSFTPCreateText: String = ""
    @State private var pendingSFTPChmod: PendingSFTPChmod?
    @State private var pendingSFTPChmodText: String = ""
    @State private var pendingSFTPFileEdit: PendingSFTPFileEdit?
    #if os(macOS)
    @State private var serverSearchFocusRequest = 0
    @State private var sftpPathFocusRequest = 0
    @State private var pendingShortcutDisconnect: WorkspaceSession?
    @State private var showingShortcutHelp = false
    #endif

    var body: some View {
        GeometryReader { proxy in
            let widths = WorkstationLayoutMetrics.widths(
                totalWidth: proxy.size.width,
                leftCollapsed: isLeftPanelCollapsed,
                rightCollapsed: isRightPanelCollapsed,
                preferredLeft: CGFloat(preferredLeftPanelWidth),
                preferredRight: CGFloat(preferredRightPanelWidth)
            )

            ZStack {
                AppChromeBackground()
                VStack(spacing: 0) {
#if os(macOS)
                    if !isTerminalFullscreen {
                        workstationTopChrome(widths: widths)
                    }
#endif
                    HStack(spacing: 0) {
                        if isTerminalFullscreen {
                            middleColumn
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            if isLeftPanelCollapsed {
                                collapsedLeftRail
                                    .frame(width: widths.left)
                            } else {
                                leftColumn
                                    .frame(width: widths.left)
                            }

                            workspaceSplitter(
                                side: .left,
                                currentWidth: widths.left
                            )

                            middleColumn
                                .frame(width: widths.middle)

                            workspaceSplitter(
                                side: .right,
                                currentWidth: widths.right
                            )

                            if isRightPanelCollapsed {
                                collapsedRail
                                    .frame(width: widths.right)
                            } else {
                                rightColumn
                                    .frame(width: widths.right)
                            }
                        }
                    }
                    // The three workspace columns own the remaining height. A
                    // detail panel in the right column must never grow the
                    // workstation or squeeze the terminal pre-input bar and
                    // independent synchronization status bar out of view.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    if !isTerminalFullscreen {
                        WorkstationPersistentSyncStatusView(
                            serverStore: serverStore,
                            syncService: syncService
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .interactiveSpring(response: 0.35, dampingFraction: 0.85), value: isRightPanelCollapsed)
        }
#if os(macOS)
        .navigationTitle("OrbitTerm")
#else
        .navigationTitle("工作站")
        .modifier(WorkstationToolbarModifier(
            serverStore: serverStore,
            syncService: syncService,
            diagnostics: diagnostics,
            showingAddServer: $showingAddServer,
            editingServer: $editingServer,
            showingAssetManager: $showingAssetManager,
            showingSettings: $showingSettings,
            showingBatchCommand: $showingBatchCommand,
            showingAccountSecurity: $showingAccountSecurity
        ))
#endif
        .modifier(WorkstationSheetsAndAlerts(
            serverStore: serverStore,
            showingAddServer: $showingAddServer,
            editingServer: $editingServer,
            pendingDeleteServer: $pendingDeleteServer,
            showingAssetManager: $showingAssetManager,
            showingSettings: $showingSettings,
            showingBatchCommand: $showingBatchCommand,
            showingAccountSecurity: $showingAccountSecurity,
            onOpenServer: { server in openServerSession(server) },
            onDeleteServer: { server in deleteServer(server) }
        ))
        .modifier(WorkstationSFTPDialogs(
            sessionManager: sessionManager,
            pendingRename: $pendingSFTPRename,
            renameText: $pendingSFTPRenameText,
            pendingCreate: $pendingSFTPCreate,
            createText: $pendingSFTPCreateText,
            pendingChmod: $pendingSFTPChmod,
            chmodText: $pendingSFTPChmodText,
            pendingFileEdit: $pendingSFTPFileEdit
        ))
        #if os(macOS)
        .modifier(MacManagementSheetsModifier(
            store: serverStore,
            showingKeyManagement: $showingKeyManagement,
            showingPortForwarding: $showingPortForwarding
        ))
        #endif
        #if os(macOS)
        .task(id: workstationShortcutStateKey) {
            shortcutCoordinator.install(workstationShortcutActions)
        }
        .onDisappear { shortcutCoordinator.clear() }
        .onChange(of: showingMonitorDetailPanelID) { _, panelID in
            guard let panelID,
                  let active = sessionManager.activeSession,
                  active.activeMonitorPanelID == panelID else { return }
            showingMonitorDetailPanelID = nil
            openWindow(value: MonitorDetailWindowRoute(sessionID: active.id))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isTerminalFullscreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isTerminalFullscreen = false
        }
        .confirmationDialog(
            "断开当前会话？",
            isPresented: Binding(
                get: { pendingShortcutDisconnect != nil },
                set: { if !$0 { pendingShortcutDisconnect = nil } }
            ),
            presenting: pendingShortcutDisconnect
        ) { tab in
            Button("断开连接", role: .destructive) {
                pendingShortcutDisconnect = nil
                Task { await sessionManager.disconnect(session: tab) }
            }
            Button("取消", role: .cancel) { pendingShortcutDisconnect = nil }
        } message: { tab in
            Text("将断开“\(tab.server.name)”的当前 SSH 会话。")
        }
        .alert("工作站快捷键", isPresented: $showingShortcutHelp) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text(workstationShortcutHelpText)
        }
        #endif
    }

#if os(macOS)
    private var workstationShortcutHelpText: String {
        func shortcut(_ action: WorkstationShortcutAction) -> String {
            shortcutPreferences.shortcut(for: action).displayString
        }
        return "\(shortcut(.addServer)) 添加服务器\n\(shortcut(.newTab)) 新建标签 · \(shortcut(.closeTab)) 关闭标签\n⌘1–⌘9 切换资产会话\n\(shortcut(.selectTerminalPane1))–\(shortcut(.selectTerminalPane4)) 切换终端分屏 1–4\n\(shortcut(.focusServerSearch)) 聚焦服务器搜索\n\(shortcut(.refreshCurrentTool)) 刷新当前 SFTP 或 Docker 工具 · \(shortcut(.refreshMonitor)) 立即刷新监控\n\(shortcut(.focusSFTPPath)) 聚焦 SFTP 路径 · \(shortcut(.goToSFTPParent)) 返回上级目录\n\(shortcut(.disconnectSession)) 断开当前会话\n\(shortcut(.settings)) 打开设置"
    }

    private var workstationShortcutStateKey: String {
        let active = sessionManager.activeSession
        return [
            sessionManager.activeTabID?.uuidString ?? "none",
            String(sessionManager.tabs.count),
            String(describing: selectedRightPanelTab),
            active?.id.uuidString ?? "none",
            active?.isConnected == true ? "connected" : "disconnected",
            active?.activeMonitorPanelID?.uuidString ?? "no-monitor",
            active?.sftpManager.isConnected == true ? "sftp" : "no-sftp",
            active?.dockerService.isConnected == true ? "docker" : "no-docker",
            String(active?.terminalSplitCount ?? 0)
        ].joined(separator: "|")
    }

    private var workstationShortcutActions: WorkstationShortcutActions {
        let active = sessionManager.activeSession
        let canUseSFTP = active?.terminalSplitCount == 0 && active?.sftpManager.isConnected == true
        let canRefreshDocker = active?.dockerService.isConnected == true
        let canRefreshMonitor = active?.activeMonitorPanelID != nil
        let terminalPaneCount = active.map {
            max($0.terminalChannelIDs.count, $0.terminalChannelID == nil ? 0 : 1)
        } ?? 0

        return WorkstationShortcutActions(
            addServer: { showingAddServer = true },
            openNewTab: {
                if let selected = serverStore.selectedServer {
                    sessionManager.quickOpenServer = selected
                }
                sessionManager.openQuickTabFromSelection()
            },
            closeActiveTab: { sessionManager.closeActiveTab() },
            canCloseActiveTab: active != nil,
            activateTab: { sessionManager.activateIndex($0) },
            activateTerminalPane: { index in
                guard let active else { return }
                guard index >= 0, index < terminalPaneCount else { return }
                active.activeTerminalPaneIndex = index
                active.terminalPaneFocusRequest &+= 1
            },
            terminalPaneCount: terminalPaneCount,
            focusServerSearch: { serverSearchFocusRequest += 1 },
            refreshCurrentTool: { refreshCurrentTool() },
            canRefreshCurrentTool: {
                switch selectedRightPanelTab {
                case .sftp: canUseSFTP
                case .docker: canRefreshDocker
                case .snippets: false
                }
            }(),
            refreshMonitor: {
                guard let panelID = active?.activeMonitorPanelID else { return }
                Task { await sessionManager.monitorService.refreshMonitoring(panelID) }
            },
            canRefreshMonitor: canRefreshMonitor,
            focusSFTPPath: {
                selectedRightPanelTab = .sftp
                sftpPathFocusRequest += 1
            },
            canFocusSFTPPath: canUseSFTP,
            goToSFTPParent: { goToSFTPParent() },
            canGoToSFTPParent: canUseSFTP && active?.sftpManager.currentPath != "/",
            disconnectActiveSession: {
                guard let active, active.isConnected else { return }
                pendingShortcutDisconnect = active
            },
            canDisconnectActiveSession: active?.isConnected == true,
            showSettings: { showingSettings = true },
            showShortcutHelp: { showingShortcutHelp = true }
        )
    }

    private func refreshCurrentTool() {
        guard let active = sessionManager.activeSession else { return }
        switch selectedRightPanelTab {
        case .sftp:
            Task { try? await active.sftpManager.refresh() }
        case .docker:
            Task { try? await active.dockerService.refreshNow() }
        case .snippets:
            break
        }
    }

    private func goToSFTPParent() {
        guard let active = sessionManager.activeSession,
              active.terminalSplitCount == 0,
              active.sftpManager.isConnected else {
            return
        }
        let parent = SFTPBrowserPathHelper.parentPath(of: active.sftpManager.currentPath)
        Task {
            guard await active.sftpManager.goToPath(parent) else { return }
            await sessionManager.syncTerminalPathFromSFTP(
                session: active,
                newPath: active.sftpManager.currentPath
            )
        }
    }

    private func workstationTopChrome(
        widths: (left: CGFloat, middle: CGFloat, right: CGFloat)
    ) -> some View {
        // The hidden-title-bar scene still reserves a native traffic-light safe
        // area. Lift this chrome as one unit so the endpoint and workspace
        // actions share that visual baseline without putting interactive views
        // over the traffic-light lane.
        VStack(spacing: 0) {
            WorkstationTopBar(
                serverStore: serverStore,
                syncService: syncService,
                diagnostics: diagnostics,
                showingAddServer: $showingAddServer,
                editingServer: $editingServer,
                showingAssetManager: $showingAssetManager,
                showingSettings: $showingSettings,
                showingBatchCommand: $showingBatchCommand,
                showingAccountSecurity: $showingAccountSecurity
            )
            WorkstationOverviewBand(
                sidebarWidth: widths.left,
                activeSession: sessionManager.activeSession,
                monitorService: sessionManager.monitorService,
                showingDetailPanelID: $showingMonitorDetailPanelID,
                onStartCheckedMonitoring: {
                    Task { await sessionManager.startMonitorForActiveSessionIfNeeded() }
                }
            )
            WorkstationTopStatusBuffer(message: session.transientStatus)
            ThemedDivider()
        }
        .offset(y: -24)
        .padding(.bottom, -24)
    }
#endif

    private var leftColumn: some View {
        WorkstationAssetSidebarView(
            serverStore: serverStore,
            sessionManager: sessionManager,
            searchText: $leftSearchText,
            searchFocusRequest: {
                #if os(macOS)
                serverSearchFocusRequest
                #else
                0
                #endif
            }(),
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
                },
                onDisconnect: { tab in
                    Task { await sessionManager.disconnect(session: tab) }
                },
                onReconnect: { tab in
                    Task {
                        if tab.isConnected {
                            await sessionManager.disconnect(session: tab)
                        }
                        await sessionManager.connect(session: tab)
                    }
                }
            )

            if let active = sessionManager.activeSession {
                WorkstationSessionContextBar(
                    session: active,
                    sessionManager: sessionManager,
                    isTerminalFullscreen: isTerminalFullscreen,
                    onToggleTerminalFullscreen: toggleTerminalFullscreen
                )
            }

            ThemedDivider()

            if let active = sessionManager.activeSession {
#if os(macOS)
                if active.server.transport == .rdp {
                    RemoteDesktopWorkspaceView(controller: active.remoteDesktopController)
                        .padding(12)
                } else {
                    TerminalSessionPane(
                        session: active,
                        sessionManager: sessionManager
                    )
                    .padding(12)
                }
#else
                TerminalSessionPane(
                    session: active,
                    sessionManager: sessionManager
                )
                .padding(12)
#endif
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
        WorkstationRightPanelView(
            sessionManager: sessionManager,
            snippetStore: snippetStore,
            selectedTab: $selectedRightPanelTab,
            sftpPathFocusRequest: {
                #if os(macOS)
                $sftpPathFocusRequest
                #else
                .constant(0)
                #endif
            }(),
            onCollapse: {
                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                    isRightPanelCollapsed = true
                }
            },
            onCreateSFTPItem: { sessionID, kind in
                pendingSFTPCreate = PendingSFTPCreate(sessionID: sessionID, kind: kind)
                pendingSFTPCreateText = ""
            },
            onRenameSFTPItem: { sessionID, item in
                pendingSFTPRename = PendingSFTPRename(sessionID: sessionID, item: item)
                pendingSFTPRenameText = item.name
            },
            onChmodSFTPItem: { sessionID, item in
                pendingSFTPChmod = PendingSFTPChmod(sessionID: sessionID, item: item)
                pendingSFTPChmodText = String(format: "%o", item.permissionsOctal & 0o7777)
            },
            onOpenSFTPFile: { sessionID, item in
                pendingSFTPFileEdit = PendingSFTPFileEdit(sessionID: sessionID, item: item)
            }
        )
    }

#if os(macOS)
    private func toggleTerminalFullscreen() {
        guard sessionManager.activeSession != nil else { return }
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
#else
    private func toggleTerminalFullscreen() { }
#endif

    private var collapsedRail: some View {
        WorkstationRightRailView {
            withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                isRightPanelCollapsed = false
            }
        }
    }

    private enum WorkspaceSplitterSide { case left, right }

    @ViewBuilder
    private func workspaceSplitter(
        side: WorkspaceSplitterSide,
        currentWidth: CGFloat
    ) -> some View {
#if os(macOS)
        Rectangle()
            .fill(palette.divider.color)
            .frame(width: 6)
            .overlay {
                Rectangle()
                    .fill(palette.accentPrimary.color.opacity(0.45))
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        switch side {
                        case .left:
                            if leftResizeOrigin == nil { leftResizeOrigin = currentWidth }
                            preferredLeftPanelWidth = Double(min(
                                320,
                                max(220, (leftResizeOrigin ?? currentWidth) + value.translation.width)
                            ))
                        case .right:
                            if rightResizeOrigin == nil { rightResizeOrigin = currentWidth }
                            preferredRightPanelWidth = Double(min(
                                420,
                                max(280, (rightResizeOrigin ?? currentWidth) - value.translation.width)
                            ))
                        }
                    }
                    .onEnded { _ in
                        leftResizeOrigin = nil
                        rightResizeOrigin = nil
                    }
            )
            .help(side == .left ? "拖动调整服务器侧栏宽度" : "拖动调整会话工具宽度")
            .accessibilityLabel(side == .left ? "调整服务器侧栏宽度" : "调整会话工具宽度")
#else
        ThemedDivider()
#endif
    }

    private func deleteServer(_ server: ServerEntry) {
        serverStore.remove(server)
        let token = session.readToken()
        let masterPassword = session.readMasterPassword()
        Task(priority: .background) {
            await syncService.deleteRemoteConfigs(
                for: [server], token: token, masterPassword: masterPassword, accountID: session.username
            )
        }
    }

}
