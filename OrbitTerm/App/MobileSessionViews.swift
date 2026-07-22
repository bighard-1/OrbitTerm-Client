import SwiftUI

#if os(iOS)
struct MobileSessionView: View {
    let onBackToAssets: () -> Void
    @Binding var selectedTab: MobileShellTab
    @EnvironmentObject private var appSession: AppSession
    @ObservedObject private var manager = SessionManager.shared
    @StateObject private var snippetStore = SnippetStore.shared
    @State private var selectedModule: MobileSessionModule = .terminal
    @AppStorage("orbitterm.mobile.quickcommands") private var quickCommandsData: String = ""
    @State private var customQuickCommands: [MobileQuickCommand] = []
    @State private var showAddQuickCommand = false
    @State private var newQuickTitle = ""
    @State private var newQuickCommand = ""
    @State private var hasLoadedRemoteSnippets = false

    private let builtInQuickCommands: [MobileQuickCommand] = [
        MobileQuickCommand(title: "更新源", command: "sudo apt update"),
        MobileQuickCommand(title: "系统升级", command: "sudo apt upgrade -y"),
        MobileQuickCommand(title: "查看负载", command: "uptime"),
        MobileQuickCommand(title: "查看磁盘", command: "df -h"),
        MobileQuickCommand(title: "查看内存", command: "free -m"),
        MobileQuickCommand(title: "查看端口", command: "ss -tulpen"),
        MobileQuickCommand(title: "重载 Nginx", command: "sudo systemctl reload nginx"),
        MobileQuickCommand(title: "查看 Docker", command: "docker ps -a")
    ]

    var body: some View {
        VStack(spacing: 0) {
            if let active = manager.activeSession {
                VStack(alignment: .leading, spacing: 10) {
                    modulePicker

                    sessionModuleContent(for: active)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "terminal")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text("暂无活动会话")
                        .font(.title3.weight(.semibold))
                    Text("在服务器页选择资产并连接后，这里会显示终端")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("返回服务器") {
                        selectedTab = .servers
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("会话")
        .navigationBarTitleDisplayMode(.inline)
        // The terminal is a dedicated workspace. Navigation happens through
        // its own controls, so the application Dock never consumes viewport
        // height on this tab.
        // A live terminal owns the full workspace. If the last session closes,
        // restore the Dock before navigating away so this view never becomes a
        // dead end after an interruption.
        .toolbar(manager.activeSession == nil ? .visible : .hidden, for: .tabBar)
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
                        if manager.tabs.count > 1 {
                            Menu {
                                ForEach(manager.tabs) { tab in
                                    Button {
                                        manager.activateTab(tab.id)
                                    } label: {
                                        HStack {
                                            Image(systemName: tab.id == active.id ? "checkmark.circle.fill" : "terminal")
                                            Text(tab.server.name)
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "rectangle.on.rectangle")
                            }
                            .accessibilityLabel("切换终端会话")
                        }
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
        .onChange(of: manager.tabs.count) { _, count in
            guard count == 0, selectedTab == .session else { return }
            selectedTab = .servers
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
            await snippetStore.pullFromCloud(
                token: appSession.readToken(),
                masterPassword: appSession.readMasterPassword(),
                accountID: appSession.username
            )
        }
    }

    private var modulePicker: some View {
        Picker("模块", selection: $selectedModule) {
            ForEach(MobileSessionModule.allCases) { module in
                Text(module.rawValue).tag(module)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private func sessionModuleContent(for session: WorkspaceSession) -> some View {
        ZStack {
            SwiftTermTerminalView(
                channelID: session.terminalChannelID,
                onResize: { cols, rows in
                    Task { await manager.resizeTerminal(session: session, cols: cols, rows: rows) }
                },
                onInput: { bytes in
                    Task { await manager.sendTerminalBytes(session: session, bytes: bytes) }
                },
                searchText: "",
                searchCommand: nil,
                onSearchFeedback: { _, _ in }
            )
            .background(.ultraThinMaterial)
            .opacity(selectedModule == .terminal ? 1 : 0)
            .allowsHitTesting(selectedModule == .terminal)
            .onAppear {
                Task { await manager.resizeTerminal(session: session, cols: 110, rows: 32) }
            }

            mobileQuickCommandsPanel(for: session)
                .opacity(selectedModule == .shortcuts ? 1 : 0)
                .allowsHitTesting(selectedModule == .shortcuts)

            MobileMonitorPanel(manager: manager, session: session)
                .opacity(selectedModule == .monitor ? 1 : 0)
                .allowsHitTesting(selectedModule == .monitor)

            SnippetsPanelView(
                snippetStore: snippetStore,
                session: session,
                onInsertCommand: { command, executeImmediately in
                    Task {
                        await manager.dispatchSnippetCommand(
                            session: session,
                            command: command,
                            executeImmediately: executeImmediately
                        )
                    }
                }
            )
            .opacity(selectedModule == .snippets ? 1 : 0)
            .allowsHitTesting(selectedModule == .snippets)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func quickCommandRow(_ item: MobileQuickCommand, session: WorkspaceSession, allowDelete: Bool) -> some View {
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
              let decoded = try? JSONDecoder().decode([MobileQuickCommand].self, from: data) else {
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
        customQuickCommands.append(MobileQuickCommand(title: title, command: command))
        persistQuickCommands()
        newQuickTitle = ""
        newQuickCommand = ""
    }

    private func deleteQuickCommands(at offsets: IndexSet) {
        customQuickCommands.remove(atOffsets: offsets)
        persistQuickCommands()
    }

}

struct MobileMoreView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var serverStore: ServerStore
    @Environment(\.appThemePalette) private var palette
    @State private var showSettings = false
    @State private var showAccountCenter = false
    @State private var showSwitchAccountConfirmation = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(palette.accentPrimary.color)
                        .accessibilityHidden(true)
                    Text(session.username)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("当前登录账户")
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary.color)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("个人中心，当前账户 \(session.username)")
            }
            .listRowBackground(Color.clear)

            Section("账户") {
                Button {
                    showAccountCenter = true
                } label: {
                    Label("个人信息管理", systemImage: "person.text.rectangle")
                }
                Button {
                    showSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }

            Section("信息") {
                NavigationLink {
                    MobileAboutView()
                } label: {
                    Label("关于 OrbitTerm", systemImage: "info.circle")
                }
                NavigationLink {
                    MobileTermsView()
                } label: {
                    Label("条款", systemImage: "doc.text")
                }
            }

            Section {
                Button {
                    showSwitchAccountConfirmation = true
                } label: {
                    Label("切换账户", systemImage: "person.crop.circle.badge.arrow.counterclockwise")
                }
                Button(role: .destructive) {
                    AccountSessionActions.leaveCurrentAccount(session: session, serverStore: serverStore)
                } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppChromeBackground())
        .navigationTitle("个人中心")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
            }
        }
        .sheet(isPresented: $showAccountCenter) {
            NavigationStack {
                AccountSecurityView()
            }
        }
        .alert("切换账户？", isPresented: $showSwitchAccountConfirmation) {
            Button("切换账户", role: .destructive) {
                AccountSessionActions.leaveCurrentAccount(session: session, serverStore: serverStore)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将断开当前所有会话并返回登录页。本机资产、片段和待同步操作会继续按原账号隔离保存。")
        }
    }
}

private struct MobileAboutView: View {
    var body: some View {
        ContentUnavailableView(
            "OrbitTerm",
            systemImage: "terminal",
            description: Text("面向多设备资产管理和安全远程会话的客户端。")
        )
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MobileTermsView: View {
    var body: some View {
        ScrollView {
            Text("使用 OrbitTerm 前，请确认您拥有目标资产的合法访问权限，并妥善保管登录凭据、主密码与密钥材料。")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("条款")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
