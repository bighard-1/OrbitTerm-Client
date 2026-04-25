import SwiftUI

struct MainWorkstationView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.openWindow) private var openWindow

    @StateObject private var serverStore = ServerStore()
    @ObservedObject private var sessionManager = SessionManager.shared

    @State private var showingAddServer = false
    @State private var isRightPanelCollapsed = false
    @State private var isStressRunning = false
    @State private var stressTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            let widths = workstationWidths(totalWidth: proxy.size.width, rightCollapsed: isRightPanelCollapsed)

            HStack(spacing: 0) {
                leftColumn
                    .frame(width: widths.left)

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
            ToolbarItem(placement: .primaryAction) {
                Button("添加服务器") { showingAddServer = true }
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
    }

    private var leftColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text("服务器")
                    .font(.headline)
                Spacer()
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
                List {
                    ForEach(serverStore.groupedServers, id: \.group) { section in
                        Section(section.group) {
                            ForEach(section.items) { server in
                                Button {
                                    serverStore.select(server)
                                    sessionManager.quickOpenServer = server
                                } label: {
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(serverStore.selectedServerID == server.id ? Color.green : Color.gray.opacity(0.4))
                                            .frame(width: 8, height: 8)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(server.name)
                                                .lineLimit(1)
                                            Text(server.endpointText)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("新建会话") {
                                        sessionManager.openTab(for: server, autoConnect: true)
                                    }
                                    Button("删除", role: .destructive) { serverStore.remove(server) }
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
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
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("终端会话")
                            .font(.headline)
                        Spacer()

                        Button("测试连接") {
                            Task { await sessionManager.testConnection(session: active) }
                        }
                        .disabled(active.server.authMethod != .password)

                        Button("连接") {
                            Task { await sessionManager.connect(session: active) }
                        }
                        .buttonStyle(.borderedProminent)

                        Button(isStressRunning ? "停止压测" : "yes 压测") {
                            toggleStressTest(for: active)
                        }
                        .buttonStyle(.bordered)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(active.server.name)
                            .font(.title3.weight(.semibold))
                        Text("\(active.server.username)@\(active.server.endpointText)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(active.terminalLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(Color.green)

                    Text("状态：\(active.terminalStatus)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        VStack(alignment: .leading, spacing: 12) {
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

            if let active = sessionManager.activeSession {
                monitorCard(for: active)
                sftpCard(for: active)
                dockerCard(for: active)
            } else {
                Text("连接终端后自动展示监控与 SFTP")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.regularMaterial)
    }

    private var collapsedRail: some View {
        VStack {
            Button {
                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                    isRightPanelCollapsed = false
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .rotationEffect(.degrees(180))
            }
            .buttonStyle(.borderless)
            .padding(.top, 12)
            Spacer()
        }
    }

    private func monitorCard(for active: WorkspaceSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("系统监控")
                .font(.subheadline.weight(.semibold))

            if let panel = sessionManager.monitorService.panel(id: active.activeMonitorPanelID) {
                Text(panel.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let p = panel.points.last {
                    metricRow(title: "CPU", value: String(format: "%.1f%%", p.cpuUsage))
                    metricRow(title: "内存", value: String(format: "%.1f%%", p.memUsedPercent))
                    metricRow(title: "磁盘", value: String(format: "%.1f%%", p.diskUsedPercent))
                    metricRow(title: "延迟", value: p.pingLatencyMs.map { String(format: "%.0fms", $0) } ?? "--")
                }
            } else {
                Text("连接终端后自动开始监控")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func sftpCard(for active: WorkspaceSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SFTP")
                .font(.subheadline.weight(.semibold))

            Text(active.sftpManager.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if active.sftpManager.items.isEmpty {
                Text("连接后自动展示远程文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(active.sftpManager.items.prefix(6)) { item in
                    HStack {
                        Image(systemName: item.iconName)
                            .foregroundStyle(item.isDirectory ? .blue : .secondary)
                        Text(item.name)
                            .lineLimit(1)
                        Spacer()
                        Text(item.formattedSize)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func dockerCard(for active: WorkspaceSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Docker")
                .font(.subheadline.weight(.semibold))

            if active.dockerService.isScanning {
                Text("正在扫描容器...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if active.dockerService.dockerEnvironmentMissing {
                Text("环境待安装，是否查看一键安装教程？")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Link("查看 Docker 官方安装文档", destination: URL(string: "https://docs.docker.com/engine/install/")!)
                    .font(.caption)
            } else if active.dockerService.cards.isEmpty {
                Text(active.dockerService.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(active.dockerService.cards.prefix(6)) { card in
                    HStack {
                        Circle()
                            .fill(card.isRunning ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.name).lineLimit(1)
                            Text(card.image).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(String(format: "CPU %.1f%%", card.cpuPercent))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        ForEach(DockerAction.allCases, id: \.self) { action in
                            Button(action.label) {
                                Task { await active.dockerService.performAction(containerID: card.id, action: action) }
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func metricRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.caption)
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

    private func workstationWidths(totalWidth: CGFloat, rightCollapsed: Bool) -> (left: CGFloat, middle: CGFloat, right: CGFloat) {
        let dividerSpace: CGFloat = 2
        let available = max(0, totalWidth - dividerSpace)

        if rightCollapsed {
            let railWidth: CGFloat = 34
            let contentSpace = max(0, available - railWidth)
            let left = max(0, contentSpace * 0.28)
            let middle = max(0, contentSpace - left)
            return (left, middle, railWidth)
        }

        let left = max(0, available * 0.20)
        let middle = max(0, available * 0.50)
        let right = max(0, available - left - middle)
        return (left, middle, right)
    }
}

struct DetachedSessionWindowView: View {
    let sessionID: UUID
    @ObservedObject private var sessionManager = SessionManager.shared

    var body: some View {
        Group {
            if let session = sessionManager.session(for: sessionID) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle().fill(session.isConnected ? Color.green : Color.gray).frame(width: 8, height: 8)
                        Text(session.server.name)
                            .font(.headline)
                        Spacer()
                        Text(session.terminalStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(session.terminalLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                    }
                    .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.green)
                }
                .padding(12)
            } else {
                ContentUnavailableView("会话已关闭", systemImage: "xmark.circle")
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}
