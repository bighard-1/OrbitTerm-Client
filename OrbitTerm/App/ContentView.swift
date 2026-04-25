import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var session: AppSession

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
