import SwiftUI

struct WorkstationAssetSidebarView: View {
    @ObservedObject var serverStore: ServerStore
    @ObservedObject var sessionManager: SessionManager
    @Binding var searchText: String
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
                        Section(section.group) {
                            ForEach(section.items) { server in
                                serverRow(server)
                            }
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
            Button(action: onAddServer) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
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
