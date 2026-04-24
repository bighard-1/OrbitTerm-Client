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
        NavigationSplitView {
            List {
                NavigationLink("服务器", destination: ServerListView())
                NavigationLink("连接测试", destination: ConnectionView())
                NavigationLink("SFTP 浏览", destination: SFTPBrowserView())
                NavigationLink("Docker 管理", destination: DockerManagerView())
                NavigationLink("性能监控", destination: MonitorDashboardView())
                NavigationLink("云同步", destination: SyncView())
            }
            .navigationTitle("OrbitTerm")
        } detail: {
            ServerListView()
                .toolbar {
                    ToolbarItem {
                        Button("退出登录") {
                            session.logout()
                        }
                    }
                }
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

            NavigationStack { SyncView() }
                .tabItem { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("退出") { session.logout() }
            }
        }
        #endif
    }
}
