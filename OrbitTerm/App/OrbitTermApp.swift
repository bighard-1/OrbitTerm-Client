import SwiftUI

@main
struct OrbitTermApp: App {
    @StateObject private var session = AppSession()
    @ObservedObject private var sessionManager = SessionManager.shared

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

        WindowGroup("会话分离", for: UUID.self) { value in
            if let sid = value.wrappedValue {
                DetachedSessionWindowView(sessionID: sid)
                    .environmentObject(session)
            } else {
                ContentUnavailableView("无可用会话", systemImage: "terminal")
            }
        }
        .defaultSize(width: 980, height: 640)
        #endif
    }

    #if os(macOS)
    var commands: some Commands {
        CommandGroup(after: .newItem) {
            Button("新建标签") {
                sessionManager.openQuickTabFromSelection()
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("关闭标签") {
                sessionManager.closeActiveTab()
            }
            .keyboardShortcut("w", modifiers: .command)

            Divider()

            Button("标签 1") { sessionManager.activateIndex(0) }
                .keyboardShortcut("1", modifiers: .command)
            Button("标签 2") { sessionManager.activateIndex(1) }
                .keyboardShortcut("2", modifiers: .command)
            Button("标签 3") { sessionManager.activateIndex(2) }
                .keyboardShortcut("3", modifiers: .command)
            Button("标签 4") { sessionManager.activateIndex(3) }
                .keyboardShortcut("4", modifiers: .command)
            Button("标签 5") { sessionManager.activateIndex(4) }
                .keyboardShortcut("5", modifiers: .command)
            Button("标签 6") { sessionManager.activateIndex(5) }
                .keyboardShortcut("6", modifiers: .command)
            Button("标签 7") { sessionManager.activateIndex(6) }
                .keyboardShortcut("7", modifiers: .command)
            Button("标签 8") { sessionManager.activateIndex(7) }
                .keyboardShortcut("8", modifiers: .command)
            Button("标签 9") { sessionManager.activateIndex(8) }
                .keyboardShortcut("9", modifiers: .command)
        }
    }
    #endif
}
