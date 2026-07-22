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
        HStack(spacing: 6) {
            Image(systemName: syncService.lastSyncMessage.contains("失败") ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.icloud.fill")
            Text(syncService.lastSyncMessage)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(syncService.lastSyncMessage.contains("失败") ? SecuritySemanticPalette().warning.color : palette.textSecondary.color)
        .help(syncService.lastSyncMessage)
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

            Spacer(minLength: 12)

            if let active = sessionManager.activeSession, active.isConnected {
                RemoteEndpointToolbarLabel(host: active.server.host)
            }

            Spacer(minLength: 12)

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
        HStack(spacing: 0) {
            WorkstationBrandOverview(width: sidebarWidth)
            // ThemedDivider is a horizontal rule by default. Pin this instance
            // to one point so it remains the sidebar boundary instead of taking
            // the flexible width that belongs to the monitor overview.
            ThemedDivider()
                .frame(width: 1, height: 60)

            if let activeSession {
                WorkstationMonitorOverviewStrip(
                    active: activeSession,
                    monitorService: monitorService,
                    onShowDetail: {
                        showingDetailPanelID = activeSession.activeMonitorPanelID
                    },
                    onStartCheckedMonitoring: onStartCheckedMonitoring
                )
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label("连接服务器后显示系统概览", systemImage: "waveform.path.ecg")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
                    .accessibilityLabel("系统概览，连接服务器后可用")
            }
        }
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

private struct RemoteEndpointToolbarLabel: View {
    @Environment(\.appThemePalette) private var palette
    let host: String

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
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(host, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.textSecondary.color)
            .help("复制完整远程地址")
            .accessibilityLabel("复制远程地址")
        }
        .foregroundStyle(palette.textPrimary.color)
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .padding(.vertical, 5)
        .background(palette.surfaceGlass.color, in: Capsule())
        .overlay {
            Capsule().stroke(palette.borderGlass.color, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("当前终端远程地址：\(host)")
    }

    private var displayHost: String {
        host.contains(":") && host.count > 22
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
            Image(systemName: "person.crop.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(palette.accentPrimary.color)
                .font(.title2.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(palette.surfaceGlass.color, in: Circle())
                .overlay {
                    Circle().stroke(palette.borderGlass.color, lineWidth: 1)
                }
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
