import SwiftUI

@main
struct OrbitTermApp: App {
    @StateObject private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
        }

        #if os(macOS)
        WindowGroup("监控看板") {
            MonitorDashboardView()
                .environmentObject(session)
        }
        .defaultSize(width: 980, height: 760)
        #endif
    }
}
