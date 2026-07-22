import SwiftUI

struct WorkstationAssetSidebarView: View {
    @Environment(\.appThemePalette) private var palette
    @ObservedObject var serverStore: ServerStore
    @ObservedObject var sessionManager: SessionManager
    @ObservedObject var syncService: SyncService
    @Binding var searchText: String
    @State private var collapsedGroups: Set<String> = []
    @State private var hoveredServerID: UUID?
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
                TextField("搜索名称、IP、用户、分组或标签", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)

                List(selection: $serverStore.selectedServerID) {
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
                                .font(.body.weight(.semibold))
                                .foregroundStyle(palette.textPrimary.color)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(palette.surfaceGlassStrong.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(palette.borderGlass.color, lineWidth: 1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 12)
                            .contentShape(Rectangle())
                            .accessibilityLabel("\(section.group)，\(section.items.count) 台服务器")
                            .accessibilityValue(isCollapsed(section.group) ? "已折叠" : "已展开")
                            .accessibilityHint(isCollapsed(section.group) ? "双击展开分组" : "双击折叠分组")
                        }
                        .listRowSeparatorTint(palette.divider.color)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(
                    LinearGradient(
                        colors: [palette.surfaceReadable.color, palette.accentPrimary.color.opacity(0.11)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .onChange(of: serverStore.selectedServerID) { _, selectedID in
                    guard let selectedID,
                          let selected = serverStore.servers.first(where: { $0.id == selectedID }) else {
                        return
                    }
                    sessionManager.quickOpenServer = selected
                }
            }

            syncStatusFooter
        }
        .background(
            LinearGradient(
                colors: [palette.surfaceReadable.color, palette.accentPrimary.color.opacity(0.13)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
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

    private var syncStatusFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: syncStatusMessage.contains("失败") ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.icloud.fill")
                .font(.caption)
            Text(syncStatusMessage)
                .lineLimit(2)
        }
        .font(.caption2)
        .foregroundStyle(
            syncStatusMessage.contains("失败")
                ? SecuritySemanticPalette().warning.color
                : palette.textSecondary.color
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(palette.surfaceGlassStrong.color)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.divider.color)
                .frame(height: 1)
        }
        .help(syncStatusMessage)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("同步状态：\(syncStatusMessage)")
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }

    private var syncStatusMessage: String {
        let message = syncService.lastSyncMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "尚未同步" : message
    }

    private func serverRow(_ server: ServerEntry) -> some View {
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
                if !server.tags.isEmpty {
                    Text(server.tags.joined(separator: " · "))
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(palette.accentSecondary.color)
                        .accessibilityLabel("标签：\(server.tags.joined(separator: "、"))")
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
        .tag(server.id)
        .scaleEffect(hoveredServerID == server.id ? 1.015 : 1, anchor: .leading)
        .animation(.easeOut(duration: 0.12), value: hoveredServerID == server.id)
#if os(macOS)
        .onHover { isHovering in
            hoveredServerID = isHovering ? server.id : nil
        }
#endif
        .onTapGesture(count: 2) {
            onOpenServer(server)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(server.name)，\(server.endpointText)，\(sessionForServer(server).map { ConnectionPresentationAdapter.checkedSSH(hasVerifiedSessionLease: $0.verifiedSessionLease != nil, hasTerminalChannel: $0.terminalChannelID != nil, isSessionUsable: $0.isConnected).label } ?? "未连接")")
        .accessibilityHint("单击选中，双击打开并连接此服务器")
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(serverStore.selectedServerID == server.id ? palette.accentPrimary.color.opacity(0.13) : Color.clear)
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

        let filtered = serverStore.servers.filter { $0.matchesSearch(query) }
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
