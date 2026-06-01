import SwiftUI

struct WorkstationToolbarModifier: ViewModifier {
    @ObservedObject var appSession: AppSession
    @ObservedObject var serverStore: ServerStore
    @ObservedObject var syncService: SyncService
    @ObservedObject var diagnostics: DiagnosticsManager
    @Binding var showingAddServer: Bool
    @Binding var editingServer: ServerEntry?
    @Binding var showingAssetManager: Bool
    @Binding var showingSettings: Bool
    @Binding var showingDiagnostics: Bool
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
                Button("批量命令") { showingBatchCommand = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("设置") { showingSettings = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("诊断") { showingDiagnostics = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("退出登录") { appSession.logout() }
            }
        }
    }
}
