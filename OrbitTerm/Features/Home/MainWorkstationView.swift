import SwiftUI

struct MainWorkstationView: View {
    @Environment(\.appThemePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var showingAccountSecurity = false
    @State private var showingBatchCommand = false
    @State private var leftSearchText = ""
    @State private var isLeftPanelCollapsed = false
    @State private var isRightPanelCollapsed = false
    @State private var selectedRightPanelTab: WorkstationRightPanelTab = .sftp
    @State private var showingMonitorDetailPanelID: UUID?
    @State private var pendingSFTPRename: PendingSFTPRename?
    @State private var pendingSFTPRenameText: String = ""
    @State private var pendingSFTPCreate: PendingSFTPCreate?
    @State private var pendingSFTPCreateText: String = ""
    @State private var pendingSFTPChmod: PendingSFTPChmod?
    @State private var pendingSFTPChmodText: String = ""
    @State private var pendingSFTPFileEdit: PendingSFTPFileEdit?

    var body: some View {
        GeometryReader { proxy in
            let widths = WorkstationLayoutMetrics.widths(
                totalWidth: proxy.size.width,
                leftCollapsed: isLeftPanelCollapsed,
                rightCollapsed: isRightPanelCollapsed
            )

            ZStack {
                AppChromeBackground()
                VStack(spacing: 0) {
#if os(macOS)
                    workstationTopChrome(widths: widths)
#endif
                    HStack(spacing: 0) {
                        if isLeftPanelCollapsed {
                            collapsedLeftRail
                                .frame(width: widths.left)
                        } else {
                            leftColumn
                                .frame(width: widths.left)
                        }

                        ThemedDivider()

                        middleColumn
                            .frame(width: widths.middle)

                        ThemedDivider()

                        if isRightPanelCollapsed {
                            collapsedRail
                                .frame(width: widths.right)
                        } else {
                            rightColumn
                                .frame(width: widths.right)
                        }
                    }
                    // The three workspace columns own the remaining height.  A
                    // detail panel in the right column must never be allowed to
                    // grow the whole workstation and squeeze the sidebar footer
                    // or terminal pre-input bar out of view.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
    }

#if os(macOS)
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
            syncService: syncService,
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
                    sessionManager: sessionManager
                )
            }

            ThemedDivider()

            if let active = sessionManager.activeSession {
                TerminalSessionPane(
                    session: active,
                    sessionManager: sessionManager
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
        WorkstationRightPanelView(
            sessionManager: sessionManager,
            snippetStore: snippetStore,
            selectedTab: $selectedRightPanelTab,
            showingMonitorDetailPanelID: $showingMonitorDetailPanelID,
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

    private var collapsedRail: some View {
        WorkstationRightRailView {
            withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                isRightPanelCollapsed = false
            }
        }
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
