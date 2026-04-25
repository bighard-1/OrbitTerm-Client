import SwiftUI
import Charts

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
    @Environment(\.openWindow) private var openWindow

    @StateObject private var serverStore = ServerStore()
    @ObservedObject private var sessionManager = SessionManager.shared
    @StateObject private var syncService = SyncService.shared

    @State private var showingAddServer = false
    @State private var editingServer: ServerEntry?
    @State private var showingAssetManager = false
    @State private var isLeftPanelCollapsed = false
    @State private var isRightPanelCollapsed = false
    @State private var isStressRunning = false
    @State private var stressTask: Task<Void, Never>?
    @State private var didRunInitialPull = false
    @AppStorage("orbitterm.terminal.line_spacing") private var terminalLineSpacing: Double = 2.0
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
        .alert("重命名", isPresented: Binding(
            get: { pendingSFTPRename != nil },
            set: { if !$0 { pendingSFTPRename = nil } }
        )) {
            TextField("新名称", text: $pendingSFTPRenameText)
            Button("取消", role: .cancel) {
                pendingSFTPRename = nil
            }
            Button("确认") {
                guard let rename = pendingSFTPRename,
                      let session = sessionManager.session(for: rename.sessionID) else {
                    pendingSFTPRename = nil
                    return
                }
                let newName = pendingSFTPRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
                pendingSFTPRename = nil
                Task { await session.sftpManager.rename(item: rename.item, to: newName) }
            }
        } message: {
            Text("请输入新的文件名")
        }
        .alert("新建项目", isPresented: Binding(
            get: { pendingSFTPCreate != nil },
            set: { if !$0 { pendingSFTPCreate = nil } }
        )) {
            TextField("名称", text: $pendingSFTPCreateText)
            Button("取消", role: .cancel) { pendingSFTPCreate = nil }
            Button("创建") {
                guard let create = pendingSFTPCreate,
                      let target = sessionManager.session(for: create.sessionID) else {
                    pendingSFTPCreate = nil
                    return
                }
                let name = pendingSFTPCreateText.trimmingCharacters(in: .whitespacesAndNewlines)
                pendingSFTPCreate = nil
                Task {
                    if create.kind == .directory {
                        await target.sftpManager.createDirectory(named: name)
                    } else {
                        await target.sftpManager.createFile(named: name)
                    }
                }
            }
        } message: {
            Text("将在当前目录创建\(pendingSFTPCreate?.kind == .directory ? "目录" : "文件")")
        }
        .alert("修改权限", isPresented: Binding(
            get: { pendingSFTPChmod != nil },
            set: { if !$0 { pendingSFTPChmod = nil } }
        )) {
            TextField("八进制权限（例如 644 / 755）", text: $pendingSFTPChmodText)
            Button("取消", role: .cancel) { pendingSFTPChmod = nil }
            Button("应用") {
                guard let chmod = pendingSFTPChmod,
                      let target = sessionManager.session(for: chmod.sessionID) else {
                    pendingSFTPChmod = nil
                    return
                }
                let mode = pendingSFTPChmodText.trimmingCharacters(in: .whitespacesAndNewlines)
                pendingSFTPChmod = nil
                Task { await target.sftpManager.chmod(item: chmod.item, modeOctal: mode) }
            }
        } message: {
            Text("请输入 3-4 位八进制权限")
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
        .task {
            await runInitialSilentPullIfNeeded()
        }
    }

    private func runInitialSilentPullIfNeeded() async {
        guard !didRunInitialPull else { return }
        didRunInitialPull = true

        SyncQueue.shared.setAuthTokenProvider {
            session.readToken()
        }

        guard let token = session.readToken(),
              let masterPassword = session.readMasterPassword() else {
            return
        }

        let ok = await syncService.pullAndApplyConfigs(
            token: token,
            masterPassword: masterPassword,
            store: serverStore
        )
        if !ok {
            session.showTransientStatus("云端拉取失败，已保留本地数据")
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
                                    Button("编辑凭据") {
                                        serverStore.select(server)
                                        editingServer = server
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
                    lineSpacing: $terminalLineSpacing,
                    isStressRunning: $isStressRunning,
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
                if let panelID = showingMonitorDetailPanelID,
                   panelID == active.activeMonitorPanelID {
                    MonitorDetailInlineView(
                        panelID: panelID,
                        service: sessionManager.monitorService,
                        onClose: { showingMonitorDetailPanelID = nil }
                    )
                }
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
            HStack {
                Text("系统监控")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("查看详情") {
                    if let panelID = active.activeMonitorPanelID {
                        showingMonitorDetailPanelID = panelID
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(active.activeMonitorPanelID == nil)
                if showingMonitorDetailPanelID == active.activeMonitorPanelID {
                    Button("收起详情") {
                        showingMonitorDetailPanelID = nil
                    }
                    .buttonStyle(.bordered)
                }
            }

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
            HStack {
                Text("SFTP")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("刷新") {
                    Task { try? await active.sftpManager.refresh() }
                }
                .buttonStyle(.bordered)
                Button("新建目录") {
                    pendingSFTPCreate = PendingSFTPCreate(sessionID: active.id, kind: .directory)
                    pendingSFTPCreateText = ""
                }
                .buttonStyle(.bordered)
                Button("新建文件") {
                    pendingSFTPCreate = PendingSFTPCreate(sessionID: active.id, kind: .file)
                    pendingSFTPCreateText = ""
                }
                .buttonStyle(.bordered)
                Button("上级") {
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
                    }
                }
                .buttonStyle(.bordered)
            }

            Text(active.sftpManager.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if active.sftpManager.items.isEmpty {
                Text("连接后自动展示远程文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(active.sftpManager.items.prefix(12)) { item in
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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard item.isDirectory else { return }
                        Task { await active.sftpManager.enterDirectory(item) }
                    }
                    .onTapGesture(count: 2) {
                        guard !item.isDirectory else { return }
                        openSFTPFileEditor(sessionID: active.id, item: item)
                    }
                    .contextMenu {
                        if item.isDirectory {
                            Button("进入目录") {
                                Task { await active.sftpManager.enterDirectory(item) }
                            }
                        } else {
                            Button("打开并编辑") {
                                openSFTPFileEditor(sessionID: active.id, item: item)
                            }
                            Button("下载到桌面") {
                                Task {
                                    let dst = desktopURL(fileName: item.name)
                                    await active.sftpManager.download(item: item, to: dst)
                                }
                            }
                        }
                        Button("重命名") {
                            pendingSFTPRename = PendingSFTPRename(sessionID: active.id, item: item)
                            pendingSFTPRenameText = item.name
                        }
                        Button("权限...") {
                            pendingSFTPChmod = PendingSFTPChmod(sessionID: active.id, item: item)
                            pendingSFTPChmodText = String(format: "%o", item.permissionsOctal & 0o7777)
                        }
                        Button("设为 644") {
                            Task { await active.sftpManager.chmod(item: item, modeOctal: "644") }
                        }
                        Button("设为 755") {
                            Task { await active.sftpManager.chmod(item: item, modeOctal: "755") }
                        }
                        Button("设为 600") {
                            Task { await active.sftpManager.chmod(item: item, modeOctal: "600") }
                        }
                        Button("删除", role: .destructive) {
                            Task { await active.sftpManager.delete(item: item) }
                        }
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
                        Button("查看日志") {
                            Task {
                                do {
                                    let logs = try await active.dockerService.fetchLogs(containerID: card.id, tailLines: 200)
                                    active.appendTerminal("[docker-logs][\(card.name)]")
                                    logs.split(separator: "\n").suffix(60).forEach { line in
                                        active.appendTerminal(String(line))
                                    }
                                } catch {
                                    active.appendTerminal("[docker-logs][error] \(error.localizedDescription)")
                                }
                            }
                        }
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

        let leftBase = available * 0.20
        let middleBase = available * 0.50
        let rightBase = max(0, available - leftBase - middleBase)

        let left = leftCollapsed ? leftRail : max(220, leftBase)
        let right = rightCollapsed ? rightRail : max(260, rightBase)
        let middle = max(320, available - left - right)
        return (left, middle, right)
    }
}

private struct PendingSFTPRename: Identifiable {
    let sessionID: UUID
    let item: FileItem

    var id: String {
        "\(sessionID.uuidString)::\(item.id)"
    }
}

private enum SFTPCreateKind {
    case file
    case directory
}

private struct PendingSFTPCreate: Identifiable {
    let sessionID: UUID
    let kind: SFTPCreateKind
    let id = UUID()
}

private struct PendingSFTPChmod: Identifiable {
    let sessionID: UUID
    let item: FileItem
    let id = UUID()
}

private struct PendingSFTPFileEdit: Identifiable {
    let sessionID: UUID
    let item: FileItem
    var id: String { "\(sessionID.uuidString)::\(item.id)" }
}

private struct TerminalSessionPane: View {
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var sessionManager: SessionManager
    @Binding var lineSpacing: Double
    @Binding var isStressRunning: Bool
    let onToggleStress: (WorkspaceSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("终端会话")
                    .font(.headline)
                Spacer()

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

            HStack(spacing: 10) {
                Text("行距")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $lineSpacing, in: 0...8)
                Text(String(format: "%.1f", lineSpacing))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(session.server.name)
                    .font(.title3.weight(.semibold))
                Text("\(session.server.username)@\(session.server.endpointText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(session.terminalLines.enumerated()), id: \.offset) { index, line in
                                Text(line.isEmpty ? " " : line)
                                    .font(.system(.body, design: .monospaced))
                                    .lineSpacing(lineSpacing)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id("line-\(session.id)-\(index)")
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("terminal-bottom-\(session.id)")
                        }
                        .padding(12)
                    }
                    .onAppear {
                        proxy.scrollTo("terminal-bottom-\(session.id)", anchor: .bottom)
                    }
                    .onChange(of: session.terminalLines.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo("terminal-bottom-\(session.id)", anchor: .bottom)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(Color.green)
                .onAppear {
                    Task {
                        let cols = Int(max(geo.size.width / 8.2, 40))
                        let rows = Int(max(geo.size.height / 18.0, 12))
                        await sessionManager.resizeTerminal(session: session, cols: cols, rows: rows)
                    }
                }
                .onChange(of: geo.size) { _, newSize in
                    Task {
                        let cols = Int(max(newSize.width / 8.2, 40))
                        let rows = Int(max(newSize.height / 18.0, 12))
                        await sessionManager.resizeTerminal(session: session, cols: cols, rows: rows)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField(
                    "输入命令后回车（真实 PTY）",
                    text: Binding(
                        get: { session.terminalInput },
                        set: { session.terminalInput = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    Task { await sessionManager.sendTerminalInput(session: session) }
                }
                Button("发送") {
                    Task { await sessionManager.sendTerminalInput(session: session) }
                }
                .buttonStyle(.borderedProminent)
            }

            Text("状态：\(session.terminalStatus)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
        percent: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let latest = points.last {
                Text(percent ? String(format: "%.1f%%", value(latest)) : String(format: "%.1f ms", value(latest)))
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
}

struct DetachedSessionWindowView: View {
    let sessionID: UUID
    @ObservedObject private var sessionManager = SessionManager.shared
    @AppStorage("orbitterm.terminal.line_spacing") private var terminalLineSpacing: Double = 2.0

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
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(session.terminalLines.enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : line)
                                    .font(.system(.body, design: .monospaced))
                                    .lineSpacing(terminalLineSpacing)
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
