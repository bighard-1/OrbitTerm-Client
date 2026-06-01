import SwiftUI
#if canImport(Charts)
import Charts
#endif
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
struct MobileSessionView: View {
    private struct QuickCommand: Identifiable, Codable, Hashable {
        let id: UUID
        var title: String
        var command: String

        init(id: UUID = UUID(), title: String, command: String) {
            self.id = id
            self.title = title
            self.command = command
        }
    }

    private enum Module: String, CaseIterable, Identifiable {
        case terminal = "终端"
        case shortcuts = "快捷指令"
        case monitor = "监控"
        var id: String { rawValue }
    }

    let onBackToAssets: () -> Void
    @Binding var selectedTab: MobileShellTab
    @EnvironmentObject private var appSession: AppSession
    @ObservedObject private var manager = SessionManager.shared
    @StateObject private var snippetStore = SnippetStore.shared
    @State private var selectedModule: Module = .terminal
    @AppStorage("orbitterm.mobile.quickcommands") private var quickCommandsData: String = ""
    @State private var customQuickCommands: [QuickCommand] = []
    @State private var showAddQuickCommand = false
    @State private var newQuickTitle = ""
    @State private var newQuickCommand = ""
    @State private var hasLoadedRemoteSnippets = false

    private let builtInQuickCommands: [QuickCommand] = [
        QuickCommand(title: "更新源", command: "sudo apt update"),
        QuickCommand(title: "系统升级", command: "sudo apt upgrade -y"),
        QuickCommand(title: "查看负载", command: "uptime"),
        QuickCommand(title: "查看磁盘", command: "df -h"),
        QuickCommand(title: "查看内存", command: "free -m"),
        QuickCommand(title: "查看端口", command: "ss -tulpen"),
        QuickCommand(title: "重载 Nginx", command: "sudo systemctl reload nginx"),
        QuickCommand(title: "查看 Docker", command: "docker ps -a")
    ]

    var body: some View {
        VStack(spacing: 0) {
            if let active = manager.activeSession {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("模块", selection: $selectedModule) {
                        ForEach(Module.allCases) { module in
                            Text(module.rawValue).tag(module)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)

                    ZStack {
                        SwiftTermTerminalView(
                            channelID: active.terminalChannelID,
                            onResize: { cols, rows in
                                Task { await manager.resizeTerminal(session: active, cols: cols, rows: rows) }
                            },
                            onInput: { bytes in
                                Task { await manager.sendTerminalBytes(session: active, bytes: bytes) }
                            },
                            searchText: "",
                            searchCommand: nil,
                            onSearchFeedback: { _, _ in }
                        )
                        .background(.ultraThinMaterial)
                        .opacity(selectedModule == .terminal ? 1 : 0)
                        .allowsHitTesting(selectedModule == .terminal)
                        .onAppear {
                            Task { await manager.resizeTerminal(session: active, cols: 110, rows: 32) }
                        }

                        mobileQuickCommandsPanel(for: active)
                            .opacity(selectedModule == .shortcuts ? 1 : 0)
                            .allowsHitTesting(selectedModule == .shortcuts)

                        mobileMonitorPanel(for: active)
                            .opacity(selectedModule == .monitor ? 1 : 0)
                            .allowsHitTesting(selectedModule == .monitor)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if selectedModule == .terminal {
                            MobileTerminalKeyboardAccessory { bytes in
                                Task {
                                    await manager.sendTerminalBytes(session: active, bytes: bytes)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ContentUnavailableView(
                    "暂无活动会话",
                    systemImage: "terminal",
                    description: Text("在服务器页选择资产并连接后，这里会显示终端")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .local)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > 50, abs(dx) > abs(dy) * 1.15 else { return }
                    if dx < 0 {
                        switchToNextModule()
                    } else {
                        switchToPreviousModule()
                    }
                }
        )
        .navigationTitle("会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let active = manager.activeSession {
                    VStack(spacing: 0) {
                        Text(active.server.name)
                            .font(.subheadline.weight(.semibold))
                        Text(active.terminalStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if let active = manager.activeSession {
                    Button {
                        manager.closeTab(active)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let active = manager.activeSession {
                    HStack(spacing: 14) {
                        Button {
                            onBackToAssets()
                        } label: {
                            Image(systemName: "list.bullet.rectangle")
                        }
                        Button {
                            Task { await manager.connect(session: active) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .onAppear {
            loadQuickCommands()
        }
        .alert("新增快捷指令", isPresented: $showAddQuickCommand) {
            TextField("标题", text: $newQuickTitle)
            TextField("命令", text: $newQuickCommand)
            Button("取消", role: .cancel) {}
            Button("保存") {
                addQuickCommand()
            }
            .disabled(newQuickTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newQuickCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("新增后可一键发送到当前终端")
        }
    }

    private func mobileQuickCommandsPanel(for session: WorkspaceSession) -> some View {
        List {
            Section("快捷键 / 组合键（点击即触发）") {
                quickActionRow("Ctrl+C", bytes: [3], session: session)
                quickActionRow("Ctrl+D", bytes: [4], session: session)
                quickActionRow("Ctrl+L", bytes: [12], session: session)
                quickActionRow("Ctrl+U", bytes: [21], session: session)
                quickActionRow("Esc", bytes: [27], session: session)
                quickActionRow("Tab", bytes: [9], session: session)
            }
            Section("常用运维") {
                ForEach(builtInQuickCommands) { item in
                    quickCommandRow(item, session: session, allowDelete: false)
                }
            }
            Section("命令片段（点击仅填入，不回车）") {
                if snippetStore.snippets.isEmpty {
                    Text("暂无命令片段")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snippetStore.snippets.prefix(20)) { snippet in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(snippet.title).font(.subheadline.weight(.semibold))
                            Text(snippet.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task {
                                await manager.dispatchSnippetCommand(
                                    session: session,
                                    command: snippet.command,
                                    executeImmediately: false
                                )
                            }
                        }
                    }
                }
            }
            Section("自定义") {
                if customQuickCommands.isEmpty {
                    Text("暂无自定义指令")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(customQuickCommands) { item in
                        quickCommandRow(item, session: session, allowDelete: true)
                    }
                    .onDelete(perform: deleteQuickCommands)
                }
                Button {
                    showAddQuickCommand = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("添加快捷指令")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .task {
            guard !hasLoadedRemoteSnippets else { return }
            hasLoadedRemoteSnippets = true
            await snippetStore.pullFromCloud(token: appSession.readToken(), masterPassword: appSession.readMasterPassword())
        }
    }

    private func quickCommandRow(_ item: QuickCommand, session: WorkspaceSession, allowDelete: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if allowDelete {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(item.command)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                await manager.dispatchSnippetCommand(
                    session: session,
                    command: item.command,
                    executeImmediately: false
                )
            }
        }
    }

    private func quickActionRow(_ title: String, bytes: [UInt8], session: WorkspaceSession) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.yellow)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                await manager.sendTerminalBytes(session: session, bytes: bytes)
            }
        }
    }

    private func loadQuickCommands() {
        guard let data = quickCommandsData.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([QuickCommand].self, from: data) else {
            customQuickCommands = []
            return
        }
        customQuickCommands = decoded
    }

    private func persistQuickCommands() {
        guard let encoded = try? JSONEncoder().encode(customQuickCommands),
              let text = String(data: encoded, encoding: .utf8) else { return }
        quickCommandsData = text
    }

    private func addQuickCommand() {
        let title = newQuickTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = newQuickCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !command.isEmpty else { return }
        customQuickCommands.append(QuickCommand(title: title, command: command))
        persistQuickCommands()
        newQuickTitle = ""
        newQuickCommand = ""
    }

    private func deleteQuickCommands(at offsets: IndexSet) {
        customQuickCommands.remove(atOffsets: offsets)
        persistQuickCommands()
    }

    private func switchToNextModule() {
        guard let idx = Module.allCases.firstIndex(of: selectedModule),
              idx < Module.allCases.count - 1 else { return }
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.88)) {
            selectedModule = Module.allCases[idx + 1]
        }
    }

    private func switchToPreviousModule() {
        guard let idx = Module.allCases.firstIndex(of: selectedModule),
              idx > 0 else { return }
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.88)) {
            selectedModule = Module.allCases[idx - 1]
        }
    }

    private func mobileMonitorPanel(for session: WorkspaceSession) -> some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 10) {
            if let panel = manager.monitorService.panel(id: session.activeMonitorPanelID) {
                Text(panel.status).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                if let last = panel.points.last {
                    HStack(spacing: 10) {
                        metric("CPU", String(format: "%.1f%%", last.cpuUsage))
                        metric("内存", String(format: "%.1f%%", last.memUsedPercent))
                        metric("磁盘", String(format: "%.1f%%", last.diskUsedPercent))
                        metric("延迟", String(format: "%.0f ms", last.pingLatencyMs ?? 0))
                        metric("下载", String(format: "%.1f KB/s", last.rxRateKBps))
                        metric("上传", String(format: "%.1f KB/s", last.txRateKBps))
                    }
                    .padding(.horizontal, 12)
                    monitorMiniCharts(panel)
                } else {
                    ContentUnavailableView("暂无监控数据", systemImage: "waveform.path.ecg")
                }
            } else {
                ContentUnavailableView("监控未启动", systemImage: "chart.line.uptrend.xyaxis")
            }
            Spacer(minLength: 0)
        }
        }
    }

    @ViewBuilder
    private func monitorMiniCharts(_ panel: MonitorPanelState) -> some View {
        let points = Array(panel.points.suffix(300)) // 5分钟窗口
#if canImport(Charts)
        VStack(spacing: 8) {
            miniChart(title: "CPU(5分钟)", points: points, value: { $0.cpuUsage }, unit: "%")
            miniChart(title: "内存(5分钟)", points: points, value: { $0.memUsedPercent }, unit: "%")
            miniChart(title: "磁盘(5分钟)", points: points, value: { $0.diskUsedPercent }, unit: "%")
            miniChart(title: "延迟(5分钟)", points: points, value: { $0.pingLatencyMs ?? 0 }, unit: "ms")
            miniChart(title: "下载(5分钟)", points: points, value: { $0.rxRateKBps }, unit: "KB/s")
            miniChart(title: "上传(5分钟)", points: points, value: { $0.txRateKBps }, unit: "KB/s")
        }
        .padding(.horizontal, 12)
#else
        EmptyView()
#endif
    }

#if canImport(Charts)
    private func miniChart(
        title: String,
        points: [MonitorPoint],
        value: @escaping (MonitorPoint) -> Double,
        unit: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f %@", value(points.last ?? MonitorPoint(time: .now, cpuUsage: 0, memUsedPercent: 0, diskUsedPercent: 0, pingLatencyMs: 0, rxRateKBps: 0, txRateKBps: 0)), unit))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Chart(points) { point in
                LineMark(
                    x: .value("t", point.time),
                    y: .value("v", value(point))
                )
                .interpolationMethod(.catmullRom)
            }
            .frame(height: 60)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
#endif

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit())
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

}

private struct MobileTerminalKeyboardAccessory: View {
    let onSend: ([UInt8]) -> Void

    private let shortcuts: [(title: String, bytes: [UInt8])] = [
        ("Tab", [9]),
        ("Ctrl+C", [3]),
        ("Esc", [27]),
        ("Ctrl+D", [4])
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(shortcuts, id: \.title) { item in
                    Button {
                        onSend(item.bytes)
                    } label: {
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 1)
        }
    }
}

struct MobileMoreView: View {
    @EnvironmentObject private var session: AppSession
    @State private var showSettings = false

    var body: some View {
        List {
            Section("工具") {
                NavigationLink("监控看板") {
                    MonitorDashboardView()
                }
                NavigationLink("命令片段") {
                    SnippetsPanelView(
                        snippetStore: SnippetStore.shared,
                        session: SessionManager.shared.activeSession,
                        onInsertCommand: { command, executeImmediately in
                            guard let active = SessionManager.shared.activeSession else { return }
                            Task {
                                await SessionManager.shared.dispatchSnippetCommand(
                                    session: active,
                                    command: command,
                                    executeImmediately: executeImmediately
                                )
                            }
                        }
                    )
                    .padding(.horizontal, 8)
                    .navigationTitle("Snippets")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }

            Section("账户") {
                Button("设置") { showSettings = true }
                Button("退出登录", role: .destructive) { session.logout() }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("更多")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}
#endif
