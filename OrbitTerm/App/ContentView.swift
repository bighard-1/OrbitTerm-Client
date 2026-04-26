import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var serverStore: ServerStore
    @StateObject private var syncService = SyncService.shared

    var body: some View {
        Group {
            if !session.isAuthenticated {
                AuthView()
            } else if !session.isUnlocked {
                MasterPasswordGateView()
            } else {
                MainShellView()
            }
        }
        .task(id: autoSyncTaskKey) {
            await runAutoSyncIfPossible()
        }
    }

    private var autoSyncTaskKey: String {
        let tokenReady = !(session.readToken()?.isEmpty ?? true)
        let masterReady = !(session.readMasterPassword()?.isEmpty ?? true)
        return "\(session.isAuthenticated)-\(session.isUnlocked)-\(tokenReady)-\(masterReady)"
    }

    private func runAutoSyncIfPossible() async {
        // 全端统一注册离线队列鉴权，避免仅桌面端可重试。
        SyncQueue.shared.setAuthTokenProvider {
            session.readToken()
        }

        guard session.isAuthenticated,
              session.isUnlocked,
              let token = session.readToken(),
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
}

private struct MainShellView: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        #if os(macOS)
        NavigationStack {
            MainWorkstationView()
        }
        #else
        TabView {
            NavigationStack { ServerListView() }
                .tabItem { Label("服务器", systemImage: "server.rack") }

            NavigationStack { ConnectionView() }
                .tabItem { Label("连接", systemImage: "network") }

            NavigationStack { SFTPBrowserView() }
                .tabItem { Label("SFTP", systemImage: "folder.badge.gearshape") }

            NavigationStack { DockerManagerView() }
                .tabItem { Label("Docker", systemImage: "shippingbox.fill") }

            NavigationStack { MonitorDashboardView() }
                .tabItem { Label("监控", systemImage: "gauge.with.dots.needle.67percent") }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("退出") { session.logout() }
            }
        }
        #endif
    }
}
