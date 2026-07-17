import SwiftUI

struct WorkstationAssetSidebarView: View {
    @Environment(\.appThemePalette) private var palette
    @ObservedObject var serverStore: ServerStore
    @ObservedObject var sessionManager: SessionManager
    @Binding var searchText: String
    @State private var collapsedGroups: Set<String> = []
    let onCollapse: () -> Void
    let onAddServer: () -> Void
    let onEditServer: (ServerEntry) -> Void
    let onOpenServer: (ServerEntry) -> Void
    let onDeleteServer: (ServerEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            if serverStore.servers.isEmpty {
                ContentUnavailableView(
                    "还没有服务器",
                    systemImage: "server.rack",
                    description: Text("点击右上角“添加服务器”开始")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextField("搜索名称、IP、用户或分组", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)

                List {
                    ForEach(filteredGroupedServers, id: \.group) { section in
                        Section {
                            if !isCollapsed(section.group) {
                                ForEach(section.items) { server in
                                    serverRow(server)
                                }
                            }
                        } header: {
                            Button {
                                toggleGroup(section.group)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isCollapsed(section.group) ? "chevron.right" : "chevron.down")
                                        .font(.caption.weight(.semibold))
                                    Text(section.group)
                                    Spacer(minLength: 0)
                                    Text("\(section.items.count)")
                                        .font(.caption2.monospacedDigit())
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .accessibilityLabel("\(section.group)，\(section.items.count) 台服务器")
                            .accessibilityValue(isCollapsed(section.group) ? "已折叠" : "已展开")
                            .accessibilityHint(isCollapsed(section.group) ? "双击展开分组" : "双击折叠分组")
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("服务器")
                .font(.headline)
            Spacer()
            Button(action: onCollapse) {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("收起服务器侧栏")
            Button(action: onAddServer) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("添加服务器")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func serverRow(_ server: ServerEntry) -> some View {
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
                            .background(palette.surfaceInput.color, in: Capsule())
                            .overlay {
                                Capsule().stroke(palette.borderGlass.color)
                            }
                            .foregroundStyle(palette.textSecondary.color)
                    }
                    HStack(spacing: 6) {
                        Text(server.endpointText)
                            .lineLimit(1)
                        ServerConnectionText(session: sessionForServer(server))
                    }
                    .font(.caption)
                        .foregroundStyle(palette.textSecondary.color)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(server.name)，\(server.endpointText)，\(sessionForServer(server).map { ConnectionPresentationAdapter.checkedSSH(hasVerifiedSessionLease: $0.verifiedSessionLease != nil, hasTerminalChannel: $0.terminalChannelID != nil, isSessionUsable: $0.isConnected).label } ?? "未连接")")
        .accessibilityHint("双击打开新会话")
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(serverStore.selectedServerID == server.id ? palette.accentPrimary.color.opacity(0.13) : Color.clear)
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onOpenServer(server)
            }
        )
        .contextMenu {
            Button("新建会话") {
                onOpenServer(server)
            }
            Button("编辑凭据") {
                serverStore.select(server)
                onEditServer(server)
            }
            Button("删除", role: .destructive) {
                onDeleteServer(server)
            }
        }
    }

    private func sessionForServer(_ server: ServerEntry) -> WorkspaceSession? {
        sessionManager.tabs.first { $0.server.id == server.id }
    }

    private var filteredGroupedServers: [(group: String, items: [ServerEntry])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func isCollapsed(_ group: String) -> Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && collapsedGroups.contains(group)
    }

    private func toggleGroup(_ group: String) {
        if collapsedGroups.contains(group) {
            collapsedGroups.remove(group)
        } else {
            collapsedGroups.insert(group)
        }
    }
}

struct WorkstationLeftRailView: View {
    let onExpand: () -> Void

    var body: some View {
        VStack {
            Button(action: onExpand) {
                Image(systemName: "sidebar.left")
                    .rotationEffect(.degrees(180))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("展开服务器侧栏")
            .padding(.top, 12)
            Spacer()
        }
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
        ConnectionStatusBadge(presentation: presentation)
    }

    private var presentation: ConnectionPresentation { ConnectionPresentationAdapter.checkedSSH(hasVerifiedSessionLease: session.verifiedSessionLease != nil, hasTerminalChannel: session.terminalChannelID != nil, isSessionUsable: session.isConnected) }
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
        ConnectionStatusRow(presentation: presentation)
            .font(.caption)
    }

    private var presentation: ConnectionPresentation { ConnectionPresentationAdapter.checkedSSH(hasVerifiedSessionLease: session.verifiedSessionLease != nil, hasTerminalChannel: session.terminalChannelID != nil, isSessionUsable: session.isConnected) }
}
