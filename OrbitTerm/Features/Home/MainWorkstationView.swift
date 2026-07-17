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

            ZStack { AppChromeBackground(); HStack(spacing: 0) {
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
            }}
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .interactiveSpring(response: 0.35, dampingFraction: 0.85), value: isRightPanelCollapsed)
        }
        .navigationTitle("工作站")
        .modifier(WorkstationToolbarModifier(
            serverStore: serverStore,
            syncService: syncService,
            diagnostics: diagnostics,
            showingAddServer: $showingAddServer,
            editingServer: $editingServer,
            showingAssetManager: $showingAssetManager,
            showingSettings: $showingSettings,
            showingBatchCommand: $showingBatchCommand
        ))
        .modifier(WorkstationSheetsAndAlerts(
            serverStore: serverStore,
            showingAddServer: $showingAddServer,
            editingServer: $editingServer,
            pendingDeleteServer: $pendingDeleteServer,
            showingAssetManager: $showingAssetManager,
            showingSettings: $showingSettings,
            showingBatchCommand: $showingBatchCommand,
            onOpenServer: { server in openServerSession(server) },
            onDeleteServer: { server in deleteServer(server) }
        ))
        .overlay(alignment: .bottom) {
            if !session.transientStatus.isEmpty {
                Text(session.transientStatus)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(palette.surfaceGlassStrong.color, in: Capsule())
                    .overlay {
                        Capsule().stroke(palette.borderGlass.color)
                    }
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
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

            if let active = sessionManager.activeSession {
                ConnectionProgressBanner(presentation: ConnectionPresentationAdapter.checkedSSH(hasVerifiedSessionLease: active.verifiedSessionLease != nil, hasTerminalChannel: active.terminalChannelID != nil, isSessionUsable: active.isConnected))
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
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
