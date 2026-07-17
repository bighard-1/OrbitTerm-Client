import SwiftUI

struct WorkstationToolbarModifier: ViewModifier {
    @Environment(\.appThemePalette) private var palette
    @EnvironmentObject private var session: AppSession
    @ObservedObject var serverStore: ServerStore
    @ObservedObject var syncService: SyncService
    @ObservedObject var diagnostics: DiagnosticsManager
    @Binding var showingAddServer: Bool
    @Binding var editingServer: ServerEntry?
    @Binding var showingAssetManager: Bool
    @Binding var showingSettings: Bool
    @Binding var showingBatchCommand: Bool

    func body(content: Content) -> some View {
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
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 6) {
                    Image(systemName: syncService.lastSyncMessage.contains("失败") ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.icloud.fill")
                    Text(syncService.lastSyncMessage)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(syncService.lastSyncMessage.contains("失败") ? SecuritySemanticPalette().warning.color : palette.textSecondary.color)
                .help(syncService.lastSyncMessage)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("添加服务器") { showingAddServer = true }
                    .buttonStyle(ThemedToolbarButtonStyle(isPrimary: true))
            }
            ToolbarItem(placement: .primaryAction) {
                Button("编辑凭据") {
                    guard let selected = serverStore.selectedServer else { return }
                    editingServer = selected
                }
                .buttonStyle(ThemedToolbarButtonStyle(isPrimary: false))
                .disabled(serverStore.selectedServer == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("资产管理") { showingAssetManager = true }
                    .buttonStyle(ThemedToolbarButtonStyle(isPrimary: false))
            }
            ToolbarItem(placement: .primaryAction) {
                Button("批量命令") { showingBatchCommand = true }
                    .buttonStyle(ThemedToolbarButtonStyle(isPrimary: false))
            }
            ToolbarItem(placement: .primaryAction) {
                Button("设置") { showingSettings = true }
                    .buttonStyle(ThemedToolbarButtonStyle(isPrimary: false))
            }
#if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                AccountToolbarMenu(
                    username: session.username,
                    openSettings: { showingSettings = true },
                    leaveAccount: {
                        AccountSessionActions.leaveCurrentAccount(
                            session: session,
                            serverStore: serverStore
                        )
                    }
                )
            }
#endif
        }
    }
}

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
    let openSettings: () -> Void
    let leaveAccount: () -> Void
    @State private var pendingAction: PendingAction?

    var body: some View {
        Menu {
            Section {
                Label(username.isEmpty ? "当前账号" : username, systemImage: "person.crop.circle")
            }
            Button {
                openSettings()
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
                .font(.title3)
        }
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
