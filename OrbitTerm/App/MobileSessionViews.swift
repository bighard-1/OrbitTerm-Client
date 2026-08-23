import SwiftUI

#if os(iOS)
import UIKit
struct MobileSessionView: View {
    let onBackToAssets: () -> Void
    @Binding var selectedTab: MobileShellTab
    @EnvironmentObject private var appSession: AppSession
    @ObservedObject private var manager = SessionManager.shared
    @StateObject private var snippetStore = SnippetStore.shared
    @State private var selectedModule: MobileSessionModule = .terminal
    @State private var terminalViewportCommand: TerminalViewportCommand?
    @AppStorage("orbitterm.mobile.terminal-key-usage.v1") private var terminalKeyUsageData: String = ""

    private let terminalKeys: [MobileTerminalKey] = [
        .init(label: "Enter", bytes: [13]), .init(label: "Ctrl+C", bytes: [3]),
        .init(label: "Ctrl+D", bytes: [4]), .init(label: "Ctrl+L", bytes: [12]),
        .init(label: "Ctrl+U", bytes: [21]), .init(label: "Esc", bytes: [27]),
        .init(label: "Tab", bytes: [9]), .init(label: "↑", bytes: [27, 91, 65]),
        .init(label: "↓", bytes: [27, 91, 66]), .init(label: "←", bytes: [27, 91, 68]),
        .init(label: "→", bytes: [27, 91, 67])
    ]

    private let terminalSymbols = ["+", "-", "*", "/", "_", "(", ")", "[", "]", "{", "}", "<", ">", "~", "#"]

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
                if manager.activeSession != nil {
                    Button {
                        onBackToAssets()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("返回服务器")
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
                            Task { await manager.connect(session: active) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("重新连接")
                        if selectedModule == .terminal {
                            Button {
                                terminalViewportCommand = .latest()
                            } label: {
                                Image(systemName: "arrow.down.to.line")
                            }
                            .accessibilityLabel("返回最新输出")
                        }
                        Button {
                            manager.closeTab(active)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .accessibilityLabel("关闭当前会话")
                    }
                }
            }
        }
        .onChange(of: manager.tabs.count) { _, count in
            guard count == 0, selectedTab == .session else { return }
            selectedTab = .servers
        }
    }

    private func mobileQuickCommandsPanel(for session: WorkspaceSession) -> some View {
        List {
            Section {
                Text("快捷操作只发送终端控制键和常用符号；需要保存、分类、同步或限定资产的命令，请使用 Snippets。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("快捷键 / 组合键（点击即触发）") {
                ForEach(orderedTerminalKeys(terminalKeys)) { key in
                    quickActionRow(key.label, bytes: key.bytes, session: session)
                }
            }
            Section("常用符号（按使用频率排序）") {
                ForEach(orderedTerminalKeys(terminalSymbols.map {
                    MobileTerminalKey(label: $0, bytes: Array($0.utf8))
                })) { key in
                    quickActionRow(key.label, bytes: key.bytes, session: session)
                }
            }
        }
        .listStyle(.insetGrouped)
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
                    manager.enqueueTerminalInput(session: session, bytes: bytes)
                },
                searchText: "",
                searchCommand: nil,
                viewportCommand: terminalViewportCommand,
                onSearchFeedback: { _, _ in }
            )
            // A UIKit terminal view owns keyboard responder and byte-stream
            // subscriptions. Make that ownership explicit per workspace so a
            // switch can never keep an earlier session's input callback alive.
            .id(session.id)
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
                    if executeImmediately {
                        selectedModule = .terminal
                    }
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

    private func quickActionRow(_ title: String, bytes: [UInt8], session: WorkspaceSession) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.yellow)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            recordTerminalKeyUse(title)
            Task {
                await manager.sendTerminalBytes(session: session, bytes: bytes)
            }
        }
    }

    private var terminalKeyUsage: [String: Int] {
        guard let data = terminalKeyUsageData.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return values
    }

    private func orderedTerminalKeys(_ keys: [MobileTerminalKey]) -> [MobileTerminalKey] {
        let usage = terminalKeyUsage
        return keys.enumerated().sorted {
            let left = usage[$0.element.label, default: 0]
            let right = usage[$1.element.label, default: 0]
            return left == right ? $0.offset < $1.offset : left > right
        }.map(\.element)
    }

    private func recordTerminalKeyUse(_ label: String) {
        var usage = terminalKeyUsage
        usage[label] = min(usage[label, default: 0] + 1, 1_000_000)
        guard let encoded = try? JSONEncoder().encode(usage),
              let text = String(data: encoded, encoding: .utf8) else { return }
        terminalKeyUsageData = text
    }

}

private struct MobileTerminalKey: Identifiable {
    let label: String
    let bytes: [UInt8]
    var id: String { label }
}

struct MobileMoreView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var serverStore: ServerStore
    @EnvironmentObject private var syncService: SyncService
    @Environment(\.appThemePalette) private var palette
    @Environment(\.openURL) private var openURL
    @State private var showSettings = false
    @State private var showAccountCenter = false
    @State private var showSwitchAccountConfirmation = false
    @State private var showKeyManagement = false
    @State private var showPortForwarding = false
    @State private var showBatchCommands = false

    var body: some View {
        ZStack {
            AppChromeBackground()
            ScrollView {
                LazyVStack(spacing: 14) {
                    MobilePersonalCenterHeader(
                        accountName: displayableAccountName,
                        accessibilityAccountName: session.username,
                        syncMessage: syncService.lastSyncMessage
                    )

                    MobilePersonalCenterCard(
                        title: "账户与安全",
                        subtitle: "登录、解锁与本机凭据保护",
                        systemImage: "person.badge.shield.checkmark"
                    ) {
                        MobilePersonalCenterActionRow(
                            title: "个人信息与安全",
                            detail: "管理登录密码、主密码与账户安全状态",
                            systemImage: "person.text.rectangle"
                        ) { showAccountCenter = true }
                    }

                    MobilePersonalCenterCard(
                        title: "设置与偏好",
                        subtitle: "界面、终端、连接、同步与诊断",
                        systemImage: "gearshape"
                    ) {
                        MobilePersonalCenterActionRow(
                            title: "设置与偏好",
                            detail: "界面、终端、同步、诊断与应用信息",
                            systemImage: "gearshape"
                        ) { showSettings = true }
                    }

                    MobilePersonalCenterCard(
                        title: "运维工具",
                        subtitle: "安全能力集中管理，避免入口散落",
                        systemImage: "wrench.and.screwdriver"
                    ) {
                        MobilePersonalCenterActionRow(
                            title: "SSH 密钥管理",
                            detail: "Keychain 本机保护与端到端加密同步",
                            systemImage: "key.horizontal"
                        ) { showKeyManagement = true }
                        MobilePersonalCenterActionRow(
                            title: "端口映射",
                            detail: "通过已验证 SSH 会话管理转发配置",
                            systemImage: "point.3.connected.trianglepath.dotted"
                        ) { showPortForwarding = true }
                        MobilePersonalCenterActionRow(
                            title: "批量命令",
                            detail: "选择多项资产并查看隔离执行回执",
                            systemImage: "terminal.fill"
                        ) { showBatchCommands = true }
                    }

                    MobilePersonalCenterCard(
                        title: "帮助与信息",
                        subtitle: "诊断、条款和版本信息",
                        systemImage: "questionmark.circle"
                    ) {
                        MobilePersonalCenterActionRow(
                            title: "帮助与反馈",
                            detail: "联系支持并反馈问题",
                            systemImage: "envelope"
                        ) {
                            if let url = URL(string: "mailto:orbitterm@163.com?subject=OrbitTerm%20iOS%20反馈") {
                                openURL(url)
                            }
                        }
                        NavigationLink {
                            MobileAboutView()
                        } label: {
                            MobilePersonalCenterNavigationLabel(
                                title: "关于 OrbitTerm",
                                detail: "查看版本和产品信息",
                                systemImage: "info.circle"
                            )
                        }
                        .buttonStyle(.plain)
                        NavigationLink {
                            MobileTermsView()
                        } label: {
                            MobilePersonalCenterNavigationLabel(
                                title: "使用条款与隐私",
                                detail: "查看授权边界、免责声明与隐私说明",
                                systemImage: "doc.text"
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    MobilePersonalCenterCard(
                        title: "当前会话",
                        subtitle: "本机数据始终按账户隔离",
                        systemImage: "lock.shield"
                    ) {
                        MobilePersonalCenterActionRow(
                            title: "切换账户",
                            detail: "断开当前会话并返回登录页",
                            systemImage: "person.crop.circle.badge.arrow.counterclockwise"
                        ) { showSwitchAccountConfirmation = true }
                        MobilePersonalCenterActionRow(
                            title: "退出登录",
                            detail: "清除当前登录会话，不删除本机加密数据",
                            systemImage: "rectangle.portrait.and.arrow.right",
                            role: .destructive
                        ) {
                            AccountSessionActions.leaveCurrentAccount(session: session, serverStore: serverStore)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .padding(.bottom, 20)
            }
        }
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
        .sheet(isPresented: $showKeyManagement) {
            MobileSSHKeyManagementView(store: serverStore)
                .environmentObject(session)
                .environmentObject(syncService)
        }
        .sheet(isPresented: $showPortForwarding) {
            MobilePortForwardingView(store: serverStore)
                .environmentObject(session)
                .environmentObject(syncService)
        }
        .sheet(isPresented: $showBatchCommands) {
            BatchCommandRunnerView(store: serverStore)
                .environmentObject(session)
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

    /// Lets exceptionally long email addresses wrap at their natural separators
    /// without changing the account identifier exposed to accessibility APIs.
    private var displayableAccountName: String {
        session.username
            .replacingOccurrences(of: "@", with: "@\u{200B}")
            .replacingOccurrences(of: ".", with: ".\u{200B}")
    }
}

private struct MobilePersonalCenterHeader: View {
    let accountName: String
    let accessibilityAccountName: String
    let syncMessage: String
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(palette.textOnAccent.color)
                .frame(width: 58, height: 58)
                .background(
                    LinearGradient(
                        colors: [palette.accentPrimary.color, palette.accentSecondary.color],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(accountName)
                    .font(.headline)
                    .foregroundStyle(palette.textPrimary.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Label(syncMessage, systemImage: "checkmark.icloud")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .modifier(ThemedGlassSurface())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("个人中心，当前账户 \(accessibilityAccountName)。同步状态：\(syncMessage)")
    }
}

private struct MobilePersonalCenterCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let content: Content
    @Environment(\.appThemePalette) private var palette

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.accentPrimary.color)
                    .frame(width: 34, height: 34)
                    .background(palette.accentPrimary.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(palette.textPrimary.color)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary.color)
                }
            }
            .padding(16)

            Divider().overlay(palette.divider.color)
            VStack(spacing: 0) { content }
        }
        .modifier(ThemedReadableSurface())
    }
}

private struct MobilePersonalCenterActionRow: View {
    let title: String
    let detail: String
    let systemImage: String
    var role: ButtonRole?
    let action: () -> Void

    init(
        title: String,
        detail: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            MobilePersonalCenterNavigationLabel(
                title: title,
                detail: detail,
                systemImage: systemImage,
                isDestructive: role == .destructive
            )
        }
        .buttonStyle(.plain)
    }
}

private struct MobilePersonalCenterNavigationLabel: View {
    let title: String
    let detail: String
    let systemImage: String
    var isDestructive = false
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isDestructive ? Color.red : palette.textSecondary.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isDestructive ? Color.red : palette.textPrimary.color)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.textSecondary.color)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.divider.color)
                .frame(height: 0.5)
                .padding(.leading, 52)
        }
    }
}

private struct MobileSSHKeyManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var syncService: SyncService
    @ObservedObject var store: ServerStore
    @ObservedObject private var keyStore = SshKeySyncStore.shared
    @State private var setupServer: ServerEntry?
    @State private var isSynchronizing = false
    @State private var showGenerator = false
    @State private var generatedKeyName = "OrbitTerm 移动端密钥"
    @State private var renameKey: SshKeySyncWire?
    @State private var renameValue = ""
    @State private var status = "私钥仅保存在 Keychain；跨端同步使用端到端加密信封。"

    private var sshServers: [ServerEntry] {
        store.servers.filter { $0.transport == .ssh }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("端到端加密密钥库") {
                    Button {
                        showGenerator = true
                    } label: {
                        Label("生成 Ed25519 密钥", systemImage: "key.horizontal.fill")
                    }
                    if keyStore.keys.isEmpty {
                        Text("暂无可复用密钥。请从下方选择一项 SSH 资产导入私钥，保存后即可加入密钥库。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(keyStore.keys, id: \.id) { key in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(key.name).font(.headline)
                                Text("\(key.format) · 已分配 \(key.assignedAssetIds.count) 项资产")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Menu("应用到资产") {
                                    ForEach(sshServers) { server in
                                        Button(server.name) { apply(key, to: server) }
                                    }
                                }
                                .buttonStyle(.bordered)
                                HStack {
                                    Button("复制公钥") { copyPublicKey(key) }
                                        .buttonStyle(.bordered)
                                    Button("备注") {
                                        renameKey = key
                                        renameValue = key.name
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .swipeActions {
                                Button("删除", role: .destructive) {
                                    do {
                                        try keyStore.delete(key.id)
                                        status = "密钥已从同步库删除；删除记录将在下次同步传播。"
                                        synchronizeLibrary()
                                    } catch {
                                        status = "无法删除密钥，请解锁账户后重试。"
                                    }
                                }
                            }
                        }
                    }
                }
                Section("SSH 资产") {
                    ForEach(sshServers) { server in
                        Button {
                            setupServer = server
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name)
                                    Text("\(server.username)@\(server.endpointText)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(server.authMethod == .key ? "已配置" : "配置密钥")
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle("SSH 密钥管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { synchronizeLibrary() } label: {
                        if isSynchronizing { ProgressView() } else { Image(systemName: "arrow.triangle.2.circlepath") }
                    }
                    .disabled(isSynchronizing)
                    .accessibilityLabel("立即同步密钥库")
                }
            }
        }
        .sheet(item: $setupServer) { server in
            QuickKeySetupSheet(server: server, store: store) { result in
                switch result {
                case .saved(let message): status = message
                case .failed(let message): status = message
                }
            }
            .environmentObject(session)
            .environmentObject(syncService)
        }
        .alert("生成 Ed25519 密钥", isPresented: $showGenerator) {
            TextField("名称 / 备注", text: $generatedKeyName)
            Button("生成") { generateKey() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("私钥会直接进入 Keychain 与端到端加密密钥库，不会在界面展示。")
        }
        .alert("修改密钥备注", isPresented: Binding(
            get: { renameKey != nil },
            set: { if !$0 { renameKey = nil } }
        )) {
            TextField("名称 / 备注", text: $renameValue)
            Button("保存") { saveRename() }
            Button("取消", role: .cancel) { renameKey = nil }
        }
    }

    private func generateKey() {
        do {
            let pair = try RustFFI.generateEd25519KeyPair(comment: generatedKeyName)
            _ = try keyStore.upsertPrivateKey(
                name: generatedKeyName.trimmingCharacters(in: .whitespacesAndNewlines),
                privateKey: pair.privateKey,
                passphrase: "",
                assetIDs: []
            )
            UIPasteboard.general.string = pair.publicKey
            status = "Ed25519 密钥已生成并安全保存，公钥已复制，可部署到目标服务器。"
            synchronizeLibrary()
        } catch {
            status = "密钥生成失败，请重试。"
        }
    }

    private func copyPublicKey(_ key: SshKeySyncWire) {
        do {
            UIPasteboard.general.string = try RustFFI.publicKey(privateKey: key.privateKey, passphrase: key.passphrase)
            status = "公钥已复制，可安全部署到目标服务器的 authorized_keys。"
        } catch {
            status = "无法从私钥派生公钥，请检查私钥口令。"
        }
    }

    private func saveRename() {
        guard let key = renameKey else { return }
        do {
            try keyStore.rename(keyID: key.id, name: renameValue)
            renameKey = nil
            status = "密钥名称与备注已更新。"
            synchronizeLibrary()
        } catch {
            status = "备注不能为空或包含无效字符。"
        }
    }

    private func apply(_ key: SshKeySyncWire, to server: ServerEntry) {
        do {
            var credentials = try CredentialVault.shared.read(for: server.credentialID) ?? .init()
            credentials.privateKeyContent = key.privateKey
            credentials.privateKeyPassphrase = key.passphrase
            var updated = server
            updated.authMethod = .key
            guard store.addOrUpdate(updated, credentials: credentials) else {
                status = "密钥未能应用到资产。"
                return
            }
            try keyStore.recordAssignment(keyID: key.id, assetID: server.id)
            status = "已将密钥应用到 \(server.name)。"
            synchronizeLibrary()
        } catch {
            status = "无法安全写入资产凭据。"
        }
    }

    private func synchronizeLibrary() {
        guard !isSynchronizing,
              let token = session.readToken(),
              let masterPassword = session.readMasterPassword() else { return }
        isSynchronizing = true
        Task {
            let succeeded = await syncService.synchronizeSshKeyLibrary(
                token: token,
                masterPassword: masterPassword,
                accountID: session.username,
                store: store
            )
            status = succeeded ? "SSH 密钥库已完成端到端加密同步。" : "同步暂不可用，本机变更已安全保留。"
            isSynchronizing = false
        }
    }
}

private struct MobileTunnelStartedPayload: Decodable {
    let baseSessionID: String
    let tunnelID: String
    let securityGeneration: CheckedFFISecurityGeneration
    let bindHost: String
    let bindPort: UInt16

    enum CodingKeys: String, CodingKey {
        case baseSessionID = "base_session_id"
        case tunnelID = "tunnel_id"
        case securityGeneration = "security_generation"
        case bindHost = "bind_host"
        case bindPort = "bind_port"
    }
}

private struct MobileTunnelStoppedPayload: Decodable {
    let tunnelID: String
    enum CodingKeys: String, CodingKey { case tunnelID = "tunnel_id" }
}

private struct MobileLocalTunnel: Identifiable {
    let id: UInt64
    let bindHost: String
    let bindPort: UInt16
    let destinationHost: String
    let destinationPort: UInt16
}

@MainActor
private final class MobilePortForwardService: ObservableObject {
    @Published private(set) var tunnels: [MobileLocalTunnel] = []
    @Published var status = "映射只在应用前台与当前已验证 SSH 会话有效。"

    func start(baseSessionID: UInt64, localPort: UInt16, destinationHost: String, destinationPort: UInt16) {
        let requestID = HostKeyRequestID()
        do {
            let json = try "127.0.0.1".withCString { bindHost in
                try destinationHost.withCString { destination in
                    try requestID.rawValue.withCString { request in
                        try OrbitCStringResultReader.orbitCore.take(
                            orbit_local_tunnel_start_checked_v1(baseSessionID, bindHost, localPort, destination, destinationPort, request)
                        )
                    }
                }
            }
            let envelope = try JSONDecoder().decode(CheckedFFIEnvelope<MobileTunnelStartedPayload>.self, from: Data(json.utf8))
            try envelope.validateRequestID(requestID)
            try envelope.validateKind(.localTunnelStarted)
            guard let payload = envelope.data,
                  payload.securityGeneration == .hostKeyVerified,
                  let tunnelID = UInt64(payload.tunnelID) else { throw CheckedFFIClientError.protocolViolation }
            tunnels.append(.init(id: tunnelID, bindHost: payload.bindHost, bindPort: payload.bindPort,
                                 destinationHost: destinationHost, destinationPort: destinationPort))
            status = "已建立 \(payload.bindHost):\(payload.bindPort) → \(destinationHost):\(destinationPort)"
        } catch {
            status = "端口映射失败，请确认会话仍在线且端口可用。"
        }
    }

    func stop(_ tunnel: MobileLocalTunnel) {
        let requestID = HostKeyRequestID()
        do {
            let json = try requestID.rawValue.withCString { request in
                try OrbitCStringResultReader.orbitCore.take(orbit_local_tunnel_stop_checked_v1(tunnel.id, request))
            }
            let envelope = try JSONDecoder().decode(CheckedFFIEnvelope<MobileTunnelStoppedPayload>.self, from: Data(json.utf8))
            try envelope.validateRequestID(requestID)
            try envelope.validateKind(.localTunnelStopped)
            tunnels.removeAll { $0.id == tunnel.id }
            status = "映射已停止。"
        } catch {
            status = "停止映射失败，会话可能已断开。"
        }
    }

    func stopAll() {
        // Work on a snapshot because stop(_:) removes from the published array.
        for tunnel in tunnels {
            stop(tunnel)
        }
    }
}

private struct MobilePortForwardingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var syncService: SyncService
    @ObservedObject var store: ServerStore
    @ObservedObject private var sessionManager = SessionManager.shared
    @ObservedObject private var profileStore = PortForwardProfileStore.shared
    @StateObject private var tunnelService = MobilePortForwardService()
    @State private var destinationHost = "127.0.0.1"
    @State private var destinationPort = "8080"
    @State private var localPort = "8080"
    @State private var synchronizeProfile = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(tunnelService.status).font(.caption).foregroundStyle(.secondary)
                }
                if let active = sessionManager.activeSession,
                   active.isConnected,
                   let lease = active.verifiedSessionLease {
                    Section("当前资产：\(active.server.name)") {
                        TextField("目标主机", text: $destinationHost)
                        TextField("目标端口", text: $destinationPort).keyboardType(.numberPad)
                        TextField("本地端口（0 表示自动分配）", text: $localPort).keyboardType(.numberPad)
                        Toggle("端到端加密同步此配置", isOn: $synchronizeProfile)
                        Button("建立映射") {
                            guard let destination = UInt16(destinationPort), destination > 0,
                                  let local = UInt16(localPort), !destinationHost.isEmpty else { return }
                            tunnelService.start(baseSessionID: lease.baseSessionID.ffiValue,
                                localPort: local, destinationHost: destinationHost, destinationPort: destination)
                        }
                        Button("保存配置") { saveProfile(for: active.server) }
                    }
                } else {
                    Section {
                        ContentUnavailableView("需要已验证 SSH 会话", systemImage: "point.3.connected.trianglepath.dotted",
                                               description: Text("先连接一台 SSH 资产，再启动端口映射；保存的配置仍可管理。"))
                    }
                }
                Section("保存的配置") {
                    if profileStore.profiles.isEmpty {
                        Text("暂无端口映射配置").foregroundStyle(.secondary)
                    }
                    ForEach(profileStore.profiles) { profile in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name)
                            Text("\(profile.bindHost):\(profile.bindPort) → \(profile.destinationHost):\(profile.destinationPort)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if let active = sessionManager.activeSession,
                               active.server.id == profile.assetID,
                               let lease = active.verifiedSessionLease {
                                Button("启动") {
                                    tunnelService.start(baseSessionID: lease.baseSessionID.ffiValue,
                                        localPort: UInt16(profile.bindPort), destinationHost: profile.destinationHost,
                                        destinationPort: UInt16(profile.destinationPort))
                                }
                            }
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                try? profileStore.delete(profile.id)
                                synchronizeProfiles()
                            }
                        }
                    }
                }
                if !tunnelService.tunnels.isEmpty {
                    Section("运行中") {
                        ForEach(tunnelService.tunnels) { tunnel in
                            HStack {
                                Text("\(tunnel.bindHost):\(tunnel.bindPort) → \(tunnel.destinationHost):\(tunnel.destinationPort)")
                                    .font(.caption.monospacedDigit())
                                Spacer()
                                Button("停止", role: .destructive) { tunnelService.stop(tunnel) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("端口映射")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
        .onDisappear { tunnelService.stopAll() }
    }

    private func saveProfile(for server: ServerEntry) {
        let host = destinationHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let destination = Int(destinationPort), (1...65_535).contains(destination),
              let local = Int(localPort), (0...65_535).contains(local), !host.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        try? profileStore.save(.init(
            id: UUID(), assetID: server.id, name: "\(host):\(destination)", mode: "local",
            bindHost: "127.0.0.1", bindPort: local, destinationHost: host,
            destinationPort: destination, createdAtUnix: now, updatedAtUnix: now,
            syncScope: synchronizeProfile ? .endToEndEncrypted : .localOnly,
            ownerAccountScope: nil
        ))
        synchronizeProfiles()
    }

    private func synchronizeProfiles() {
        guard let token = session.readToken(), let masterPassword = session.readMasterPassword() else { return }
        Task {
            _ = await syncService.pullAndApplyConfigs(token: token, masterPassword: masterPassword,
                store: store, accountID: session.username, incremental: true, silentStart: true)
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
            Text(OrbitLegalTerms.fullText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("使用条款")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
