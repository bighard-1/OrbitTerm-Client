import SwiftUI

private enum WorkstationSheetLayout {
    static let width: CGFloat = 560
    static let height: CGFloat = 640
}

struct WorkstationSheetsAndAlerts: ViewModifier {
    @EnvironmentObject private var session: AppSession

    @ObservedObject var serverStore: ServerStore
    @Binding var showingAddServer: Bool
    @Binding var editingServer: ServerEntry?
    @Binding var pendingDeleteServer: ServerEntry?
    @Binding var showingAssetManager: Bool
    @Binding var showingSettings: Bool
    @Binding var showingBatchCommand: Bool
    @Binding var showingAccountSecurity: Bool

    let onOpenServer: (ServerEntry) -> Void
    let onDeleteServer: (ServerEntry) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingAddServer) {
                AddServerView(store: serverStore) { server in
                    onOpenServer(server)
                }
                .environmentObject(session)
#if os(macOS)
                .frame(width: WorkstationSheetLayout.width, height: WorkstationSheetLayout.height)
#endif
            }
            .sheet(item: $editingServer) { server in
                AddServerView(store: serverStore, editingServer: server) { updated in
                    onOpenServer(updated)
                }
                .environmentObject(session)
#if os(macOS)
                .frame(width: WorkstationSheetLayout.width, height: WorkstationSheetLayout.height)
#endif
            }
            .sheet(isPresented: $showingAssetManager) {
                AssetManagerView(
                    store: serverStore,
                    onEdit: { server in editingServer = server },
                    onConnect: { server in onOpenServer(server) }
                )
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView()
                }
#if os(macOS)
                    .frame(width: WorkstationSheetLayout.width, height: WorkstationSheetLayout.height)
#endif
            }
            .sheet(isPresented: $showingAccountSecurity) {
                NavigationStack {
                    AccountSecurityView()
                }
#if os(macOS)
                .frame(width: WorkstationSheetLayout.width, height: WorkstationSheetLayout.height)
#endif
            }
            .sheet(isPresented: $showingBatchCommand) {
                BatchCommandRunnerView(store: serverStore)
#if os(macOS)
                    .frame(minWidth: 980, minHeight: 680)
#endif
            }
            .alert("确认删除资产", isPresented: Binding(
                get: { pendingDeleteServer != nil },
                set: { if !$0 { pendingDeleteServer = nil } }
            )) {
                Button("取消", role: .cancel) { pendingDeleteServer = nil }
                Button("删除", role: .destructive) {
                    guard let server = pendingDeleteServer else { return }
                    pendingDeleteServer = nil
                    onDeleteServer(server)
                }
            } message: {
                Text("将删除“\(pendingDeleteServer?.name ?? "该资产")”的本地记录，并尝试同步云端删除。此操作不可撤销。")
            }
    }
}
