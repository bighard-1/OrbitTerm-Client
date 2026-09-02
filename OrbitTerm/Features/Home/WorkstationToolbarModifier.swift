import SwiftUI

struct WorkstationToolbarModifier: ViewModifier {
    @Environment(\.appThemePalette) private var palette
    @EnvironmentObject private var session: AppSession
    @ObservedObject var serverStore: ServerStore
    @ObservedObject var syncService: SyncService
    @ObservedObject var diagnostics: DiagnosticsManager
    @ObservedObject private var sessionManager = SessionManager.shared
    @Binding var showingAddServer: Bool
    @Binding var editingServer: ServerEntry?
    @Binding var showingAssetManager: Bool
    @Binding var showingSettings: Bool
    @Binding var showingBatchCommand: Bool
    @Binding var showingAccountSecurity: Bool

    func body(content: Content) -> some View {
#if os(macOS)
        content
#else
        content.toolbar {
#if DEBUG
            ToolbarItem(placement: .automatic) {
                DebugFPSBadge()
            }
#endif
            ToolbarItem(placement: .automatic) {
                if diagnostics.isRetrying {
                    ProgressView()
                        .controlSize(.small)
                        .help("网络重试中")
                }
            }
            ToolbarItem(placement: .automatic) { syncStatus }
            workstationActions
        }
#endif
    }

    @ToolbarContentBuilder
    private var workstationActions: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("添加服务器") { showingAddServer = true }
                .buttonStyle(ThemedToolbarButtonStyle(isPrimary: true))
        }
        ToolbarItem(placement: .automatic) {
            Button("编辑凭据") {
                guard let selected = serverStore.selectedServer else { return }
                editingServer = selected
            }
            .buttonStyle(ThemedToolbarButtonStyle(isPrimary: false))
            .disabled(serverStore.selectedServer == nil)
        }
        ToolbarItem(placement: .automatic) {
            Button("资产管理") { showingAssetManager = true }
                .buttonStyle(ThemedToolbarButtonStyle(isPrimary: false))
        }
        ToolbarItem(placement: .automatic) {
            Button("批量命令") { showingBatchCommand = true }
                .buttonStyle(ThemedToolbarButtonStyle(isPrimary: false))
        }
        ToolbarItem(placement: .automatic) {
            Button("设置") { showingSettings = true }
                .buttonStyle(ThemedToolbarButtonStyle(isPrimary: false))
        }
    }

    private var syncStatus: some View {
        let recovery = syncService.lastRecoveryPresentation
        return HStack(spacing: 6) {
            Image(systemName: recovery?.systemImage ?? "checkmark.icloud.fill")
            Text(recovery.map { "\($0.title)：\($0.message)" } ?? syncService.lastSyncMessage)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(
            recovery == nil
                ? palette.textSecondary.color
                : (recovery?.severity == .danger ? SecuritySemanticPalette().danger.color : SecuritySemanticPalette().warning.color)
        )
        .help(recovery?.diagnosticCode ?? syncService.lastSyncMessage)
    }
}

#if os(macOS)
struct WorkstationTopBar: View {
    @Environment(\.appThemePalette) private var palette
    @EnvironmentObject private var session: AppSession
    @ObservedObject var serverStore: ServerStore
    @ObservedObject var syncService: SyncService
    @ObservedObject var diagnostics: DiagnosticsManager
    @ObservedObject private var sessionManager = SessionManager.shared
    @Binding var showingAddServer: Bool
    @Binding var editingServer: ServerEntry?
    @Binding var showingAssetManager: Bool
    @Binding var showingSettings: Bool
    @Binding var showingBatchCommand: Bool
    @Binding var showingAccountSecurity: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Reserve the native traffic-light lane. It is deliberately a
            // layout spacer rather than a transparent view, so AppKit retains
            // the system controls' hover and click handling.
            Spacer(minLength: 0)
                .frame(width: 62)

#if DEBUG
            DebugFPSBadge()
#endif
            if diagnostics.isRetrying {
                ProgressView()
                    .controlSize(.small)
                    .help("网络重试中")
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button("添加服务器") { showingAddServer = true }
                    .buttonStyle(WorkstationTopBarButtonStyle(isPrimary: true))
                Button("编辑凭据") {
                    guard let selected = serverStore.selectedServer else { return }
                    editingServer = selected
                }
                .buttonStyle(WorkstationTopBarButtonStyle(isPrimary: false))
                .disabled(serverStore.selectedServer == nil)
                Button("资产管理") { showingAssetManager = true }
                    .buttonStyle(WorkstationTopBarButtonStyle(isPrimary: false))
                Button("密钥管理") {
                    NotificationCenter.default.post(name: .orbitTermOpenKeyManagement, object: nil)
                }
                .buttonStyle(WorkstationTopBarButtonStyle(isPrimary: false))
                Button("端口映射") {
                    NotificationCenter.default.post(name: .orbitTermOpenPortForwarding, object: nil)
                }
                .buttonStyle(WorkstationTopBarButtonStyle(isPrimary: false))
                Button("批量命令") { showingBatchCommand = true }
                    .buttonStyle(WorkstationTopBarButtonStyle(isPrimary: false))
                Button("设置") { showingSettings = true }
                    .buttonStyle(WorkstationTopBarButtonStyle(isPrimary: false))
                AccountToolbarMenu(
                    username: session.username,
                    openAccountSecurity: { showingAccountSecurity = true },
                    leaveAccount: {
                        AccountSessionActions.leaveCurrentAccount(
                            session: session,
                            serverStore: serverStore
                        )
                    }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .background(palette.surfaceGlassStrong.color)
    }

}

struct WorkstationBrandOverview: View {
    @Environment(\.appThemePalette) private var palette
    let width: CGFloat

    private var isCompact: Bool { width < 140 }

    var body: some View {
        HStack(spacing: 8) {
            Image("OrbitTermLogo")
                .resizable()
                .scaledToFit()
                .frame(width: isCompact ? 32 : 48, height: isCompact ? 32 : 48)
                .clipShape(RoundedRectangle(cornerRadius: isCompact ? 10 : 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: isCompact ? 10 : 14, style: .continuous)
                        .stroke(palette.borderGlass.color.opacity(0.8), lineWidth: 1)
                }
                .shadow(color: palette.accentPrimary.color.opacity(0.24), radius: isCompact ? 4 : 7, y: 1)
                .accessibilityHidden(true)

            if !isCompact {
                Text("OrbitTerm")
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .foregroundStyle(palette.textPrimary.color)
                    .accessibilityLabel("OrbitTerm 工作站")
            }
        }
        .padding(.leading, 12)
        .frame(width: width, height: 60, alignment: .leading)
    }
}

struct WorkstationOverviewBand: View {
    let sidebarWidth: CGFloat
    let activeSession: WorkspaceSession?
    @ObservedObject var monitorService: MonitorService
    @Binding var showingDetailPanelID: UUID?
    let onStartCheckedMonitoring: () -> Void
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            RemoteEndpointMonitorCard(
                host: activeSession?.isConnected == true ? activeSession?.server.host : nil
            )
            .frame(width: 176)

            Group {
                if let activeSession {
                WorkstationMonitorOverviewStrip(
                    active: activeSession,
                    monitorService: monitorService,
                    onShowDetail: {
                        showingDetailPanelID = activeSession.activeMonitorPanelID
                    },
                    onStartCheckedMonitoring: onStartCheckedMonitoring
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Label("连接服务器后显示系统概览", systemImage: "waveform.path.ecg")
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("系统概览，连接服务器后可用")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .frame(height: 60)
        .background(palette.surfaceGlassStrong.color)
    }
}

struct WorkstationTopStatusBuffer: View {
    @Environment(\.appThemePalette) private var palette
    let message: String

    var body: some View {
        Group {
            if message.isEmpty {
                Color.clear
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption2)
                    Text(message)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(palette.textSecondary.color)
                .padding(.horizontal, 12)
            }
        }
        .frame(height: message.isEmpty ? 14 : 24)
        .background(palette.surfaceGlassStrong.color)
        .accessibilityElement(children: message.isEmpty ? .ignore : .combine)
        .accessibilityLabel(message)
    }
}

private struct WorkstationTopBarButtonStyle: ButtonStyle {
    let isPrimary: Bool
    @Environment(\.appThemePalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(isPrimary ? palette.textOnAccent.color : palette.textPrimary.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isPrimary
                    ? palette.accentPrimary.color.opacity(configuration.isPressed ? 0.78 : 1)
                    : palette.surfaceGlass.color.opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isPrimary ? palette.accentPrimary.color.opacity(0.9) : palette.borderGlass.color,
                        lineWidth: 1
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct RemoteEndpointMonitorCard: View {
    @Environment(\.appThemePalette) private var palette
    let host: String?

    var body: some View {
        HStack(spacing: 5) {
            Text("当前资产 IP")
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.textSecondary.color)
            Text(displayHost)
                .font(.caption.monospaced())
                .lineLimit(1)
            Rectangle()
                .fill(palette.borderGlass.color)
                .frame(width: 1, height: 13)
            Button {
                guard let host else { return }
                _ = SecureClipboard.copy(host, kind: .ordinaryText)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(host == nil)
            .foregroundStyle(palette.textSecondary.color)
            .help("复制完整远程地址")
            .accessibilityLabel("复制远程地址")
        }
        .foregroundStyle(palette.textPrimary.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 50, maxHeight: 50, alignment: .leading)
        .background(palette.surfaceGlass.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.borderGlass.color, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("当前终端远程地址：\(host ?? "未连接")")
    }

    private var displayHost: String {
        guard let host else { return "未连接" }
        return host.contains(":") && host.count > 22
            ? "\(host.prefix(10))…\(host.suffix(8))"
            : host
    }
}

#endif

private struct AccountToolbarMenu: View {
    enum PendingAction: Hashable, Identifiable {
        case switchAccount
        case logout

        var id: Self { self }
        var title: String {
            switch self {
            case .switchAccount: "切换账号？"
            case .logout: "退出登录？"
            }
        }
        var confirmationLabel: String {
            switch self {
            case .switchAccount: "切换账号"
            case .logout: "退出登录"
            }
        }
    }

    @Environment(\.appThemePalette) private var palette
    let username: String
    let openAccountSecurity: () -> Void
    let leaveAccount: () -> Void
    @State private var pendingAction: PendingAction?

    var body: some View {
        Menu {
            Section {
                Label(username.isEmpty ? "当前账号" : username, systemImage: "person.crop.circle")
            }
            Button {
                openAccountSecurity()
            } label: {
                Label("管理个人信息", systemImage: "person.text.rectangle")
            }
            Divider()
            Button {
                pendingAction = .switchAccount
            } label: {
                Label("切换账号", systemImage: "person.crop.circle.badge.arrow.counterclockwise")
            }
            Button(role: .destructive) {
                pendingAction = .logout
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            Label("个人中心", systemImage: "person.crop.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.textPrimary.color)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(palette.surfaceGlass.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(palette.borderGlass.color) }
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(username.isEmpty ? "账户菜单" : "账户菜单，当前账号 \(username)")
        .help(username.isEmpty ? "账户菜单" : "当前账号：\(username)")
        .confirmationDialog(
            pendingAction?.title ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingAction?.confirmationLabel ?? "确认", role: .destructive) {
                pendingAction = nil
                leaveAccount()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将断开当前所有会话并返回登录页。本机资产、片段和待同步操作会继续按原账号隔离保存，不会交给下一个账号。")
        }
    }
}

extension Notification.Name {
    static let orbitTermOpenKeyManagement = Notification.Name("orbitTerm.openKeyManagement")
    static let orbitTermOpenPortForwarding = Notification.Name("orbitTerm.openPortForwarding")
}

#if os(macOS)
struct MacManagementSheetsModifier: ViewModifier {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var syncService: SyncService
    @ObservedObject var store: ServerStore
    @Binding var showingKeyManagement: Bool
    @Binding var showingPortForwarding: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .orbitTermOpenKeyManagement)) { _ in
                showingKeyManagement = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .orbitTermOpenPortForwarding)) { _ in
                showingPortForwarding = true
            }
            .sheet(isPresented: $showingKeyManagement) {
                MacSSHKeyManagementView(store: store)
                    .environmentObject(session)
                    .environmentObject(syncService)
                    .frame(minWidth: 680, minHeight: 520)
            }
            .sheet(isPresented: $showingPortForwarding) {
                MacPortForwardingView()
                    .frame(minWidth: 680, minHeight: 500)
            }
    }
}

struct MacSSHKeyManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appThemePalette) private var palette
    @ObservedObject var store: ServerStore
    @ObservedObject private var synchronizedKeyStore = SshKeySyncStore.shared
    @State private var selectedServerID: UUID?
    @State private var serverForSetup: ServerEntry?
    @State private var searchText = ""
    @State private var filter: AssetKeyFilter = .all

    private enum AssetKeyFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case configured = "已配置"
        case unconfigured = "未配置"
        var id: String { rawValue }
    }

    private var sshServers: [ServerEntry] {
        store.servers.filter { $0.transport == .ssh }
    }

    private var filteredServers: [ServerEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return sshServers.filter { server in
            let matchesFilter = switch filter {
            case .all: true
            case .configured: server.authMethod == .key
            case .unconfigured: server.authMethod != .key
            }
            let matchesSearch = query.isEmpty ||
                server.name.localizedCaseInsensitiveContains(query) ||
                server.host.localizedCaseInsensitiveContains(query) ||
                server.username.localizedCaseInsensitiveContains(query) ||
                server.group.localizedCaseInsensitiveContains(query)
            return matchesFilter && matchesSearch
        }
    }

    private var selectedServer: ServerEntry? {
        guard let selectedServerID else { return nil }
        return sshServers.first { $0.id == selectedServerID }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本机密钥库与资产部署")
                        .font(.headline)
                    Text("仅列出 SSH 资产；RDP 与 Telnet 不使用 SSH 密钥。私钥始终保存在系统安全凭据库，同步时仅上传端到端加密信封。")
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary.color)
                }

                HStack(spacing: 10) {
                    TextField("搜索名称、主机、用户或分组", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    Picker("状态", selection: $filter) {
                        ForEach(AssetKeyFilter.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }

                if sshServers.isEmpty {
                    ContentUnavailableView("暂无 SSH 资产", systemImage: "key", description: Text("先添加 SSH 资产，再配置密钥。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HSplitView {
                        List(filteredServers, selection: $selectedServerID) { server in
                            HStack(spacing: 10) {
                                Image(systemName: server.authMethod == .key ? "key.horizontal.fill" : "key.horizontal")
                                    .foregroundStyle(server.authMethod == .key ? palette.accentPrimary.color : palette.textSecondary.color)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(server.name).lineLimit(1)
                                    Text("\(server.username)@\(server.endpointText)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(palette.textSecondary.color)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Text(server.authMethod == .key ? "已配置" : "未配置")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(server.authMethod == .key ? palette.accentPrimary.color : palette.textSecondary.color)
                            }
                            .tag(server.id)
                            .contentShape(Rectangle())
                        }
                        .listStyle(.inset)
                        .frame(minWidth: 300, idealWidth: 340)

                        keyDetail
                            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .padding(16)
            .navigationTitle("SSH 密钥管理")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            }
        }
        .sheet(item: $serverForSetup) { server in
            QuickKeySetupSheet(server: server, store: store) { _ in serverForSetup = nil }
        }
        .onAppear { selectFirstVisibleServerIfNeeded() }
        .onChange(of: searchText) { _, _ in selectFirstVisibleServerIfNeeded() }
        .onChange(of: filter) { _, _ in selectFirstVisibleServerIfNeeded() }
    }

    @ViewBuilder
    private var keyDetail: some View {
        if let server = selectedServer {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "key.viewfinder")
                    .font(.title)
                    .foregroundStyle(palette.accentPrimary.color)
                Text(server.name)
                    .font(.title3.weight(.semibold))
                Text("\(server.username)@\(server.endpointText)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(palette.textSecondary.color)
                    .textSelection(.enabled)
                LabeledContent("认证方式", value: server.authMethod == .key ? "SSH 私钥" : "密码")
                LabeledContent("同步范围", value: "跟随资产的端到端加密同步")
                Divider()
                Text("导入或替换私钥、生成并部署 Ed25519、连接测试与关闭密码回退统一在安全配置流程内完成。")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    serverForSetup = server
                } label: {
                    Label(server.authMethod == .key ? "管理或替换密钥" : "配置并部署密钥", systemImage: "key.horizontal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ThemedPrimaryButtonStyle())
                if !synchronizedKeyStore.keys.isEmpty {
                    Divider()
                    Text("端到端加密密钥库").font(.headline)
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(synchronizedKeyStore.keys, id: \.id) { key in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(key.name).lineLimit(1)
                                        Text("\(key.format) · 已分配 \(key.assignedAssetIds.count) 项资产")
                                            .font(.caption).foregroundStyle(palette.textSecondary.color)
                                    }
                                    Spacer()
                                    Button("应用") {
                                        applySynchronizedKey(key, to: server)
                                    }
                                    Button("删除", role: .destructive) {
                                        try? synchronizedKeyStore.delete(key.id)
                                    }
                                }
                                .padding(8)
                                .themedReadableSurface()
                            }
                        }
                    }
                    .frame(maxHeight: 190)
                }
                Spacer()
            }
            .padding(18)
            .themedReadableSurface()
        } else {
            ContentUnavailableView("选择一项 SSH 资产", systemImage: "key.horizontal", description: Text("随后可导入、生成、部署并测试密钥。"))
        }
    }

    private func selectFirstVisibleServerIfNeeded() {
        if let selectedServerID, filteredServers.contains(where: { $0.id == selectedServerID }) {
            return
        }
        selectedServerID = filteredServers.first?.id
    }

    private func applySynchronizedKey(_ key: SshKeySyncWire, to server: ServerEntry) {
        do {
            let vault = CredentialVault.shared
            var credentials = try vault.read(for: server.credentialID) ?? .init()
            credentials.privateKeyContent = key.privateKey
            credentials.privateKeyPassphrase = key.passphrase
            var updatedServer = server
            updatedServer.authMethod = .key
            guard store.addOrUpdate(updatedServer, credentials: credentials) else { return }
            try synchronizedKeyStore.recordAssignment(keyID: key.id, assetID: server.id)
        } catch {
            // Private material is never echoed into the UI or diagnostics.
        }
    }
}

private struct LocalTunnelStartedPayload: Decodable {
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

private struct LocalTunnelStoppedPayload: Decodable {
    let tunnelID: String
    enum CodingKeys: String, CodingKey { case tunnelID = "tunnel_id" }
}

private struct MacLocalTunnel: Identifiable {
    let id: UInt64
    let bindHost: String
    let bindPort: UInt16
    let destinationHost: String
    let destinationPort: UInt16
}

@MainActor
private final class MacPortForwardService: ObservableObject {
    @Published private(set) var tunnels: [MacLocalTunnel] = []
    @Published var message = "端口映射仅绑定本机 127.0.0.1，并复用当前已验证 SSH 会话。"

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
            let envelope = try JSONDecoder().decode(CheckedFFIEnvelope<LocalTunnelStartedPayload>.self, from: Data(json.utf8))
            try envelope.validateRequestID(requestID)
            try envelope.validateKind(.localTunnelStarted)
            guard let payload = envelope.data,
                  payload.securityGeneration == .hostKeyVerified,
                  payload.baseSessionID == String(baseSessionID),
                  let tunnelID = UInt64(payload.tunnelID) else { throw CheckedFFIClientError.protocolViolation }
            tunnels.append(MacLocalTunnel(id: tunnelID, bindHost: payload.bindHost, bindPort: payload.bindPort, destinationHost: destinationHost, destinationPort: destinationPort))
            message = "已建立 127.0.0.1:\(payload.bindPort) → \(destinationHost):\(destinationPort)"
        } catch {
            message = "端口映射失败：\(error.localizedDescription)"
        }
    }

    func stop(_ tunnel: MacLocalTunnel) {
        let requestID = HostKeyRequestID()
        do {
            let json = try requestID.rawValue.withCString { request in
                try OrbitCStringResultReader.orbitCore.take(orbit_local_tunnel_stop_checked_v1(tunnel.id, request))
            }
            let envelope = try JSONDecoder().decode(CheckedFFIEnvelope<LocalTunnelStoppedPayload>.self, from: Data(json.utf8))
            try envelope.validateRequestID(requestID)
            try envelope.validateKind(.localTunnelStopped)
            guard envelope.data?.tunnelID == String(tunnel.id) else { throw CheckedFFIClientError.protocolViolation }
            tunnels.removeAll { $0.id == tunnel.id }
            message = "已停止本地端口 \(tunnel.bindPort) 的映射。"
        } catch {
            message = "停止映射失败：\(error.localizedDescription)"
        }
    }

    func stopAll() {
        for tunnel in tunnels {
            stop(tunnel)
        }
    }
}

struct MacPortForwardingView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sessionManager = SessionManager.shared
    @StateObject private var service = MacPortForwardService()
    @ObservedObject private var profileStore = PortForwardProfileStore.shared
    @State private var destinationHost = "127.0.0.1"
    @State private var destinationPort = "8080"
    @State private var localPort = "8080"

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                if let active = sessionManager.activeSession, active.isConnected, let lease = active.verifiedSessionLease {
                    LabeledContent("当前已验证资产", value: "\(active.server.name) · \(active.server.endpointText)")
                    HStack {
                        TextField("目标主机", text: $destinationHost)
                        TextField("目标端口", text: $destinationPort).frame(width: 110)
                        TextField("本地端口", text: $localPort).frame(width: 110)
                        Button("建立映射") {
                            let host = destinationHost.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard let destination = UInt16(destinationPort), destination > 0,
                                  let local = UInt16(localPort), local > 0,
                                  !host.isEmpty else { return }
                            service.start(baseSessionID: lease.baseSessionID.ffiValue, localPort: local, destinationHost: host, destinationPort: destination)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("保存配置") {
                            let host = destinationHost.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard let destination = Int(destinationPort), (1...65_535).contains(destination),
                                  let local = Int(localPort), (0...65_535).contains(local), !host.isEmpty else { return }
                            let now = Int64(Date().timeIntervalSince1970)
                            try? profileStore.save(SavedPortForwardProfile(
                                id: UUID(), assetID: active.server.id,
                                name: "\(host):\(destination)", mode: "local",
                                bindHost: "127.0.0.1", bindPort: local,
                                destinationHost: host, destinationPort: destination,
                                createdAtUnix: now, updatedAtUnix: now,
                                syncScope: .endToEndEncrypted,
                                ownerAccountScope: nil
                            ))
                        }
                    }
                } else {
                    ContentUnavailableView("需要已验证 SSH 会话", systemImage: "point.3.connected.trianglepath.dotted", description: Text("先连接一台 SSH 资产，再建立本地端口映射。"))
                }
                Text(service.message).font(.caption).foregroundStyle(.secondary)
                if let active = sessionManager.activeSession {
                    Section("保存的配置") {
                        ForEach(profileStore.profiles.filter { $0.assetID == active.server.id }) { profile in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(profile.name)
                                    Text("\(profile.bindHost):\(profile.bindPort) → \(profile.destinationHost):\(profile.destinationPort) · \(profile.syncScope == .endToEndEncrypted ? "加密同步" : "仅本机")")
                                        .font(.caption).foregroundStyle(.secondary).monospaced()
                                }
                                Spacer()
                                if let lease = active.verifiedSessionLease {
                                    Button("启动") {
                                        service.start(baseSessionID: lease.baseSessionID.ffiValue,
                                            localPort: UInt16(profile.bindPort), destinationHost: profile.destinationHost,
                                            destinationPort: UInt16(profile.destinationPort))
                                    }
                                }
                                Button("删除", role: .destructive) { try? profileStore.delete(profile.id) }
                            }
                        }
                    }
                }
                List(service.tunnels) { tunnel in
                    HStack {
                        Text("\(tunnel.bindHost):\(tunnel.bindPort)").monospaced()
                        Image(systemName: "arrow.right")
                        Text("\(tunnel.destinationHost):\(tunnel.destinationPort)").monospaced()
                        Spacer()
                        Button("停止", role: .destructive) { service.stop(tunnel) }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("端口映射")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
        .onDisappear { service.stopAll() }
    }
}
#endif
