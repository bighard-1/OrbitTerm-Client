import SwiftUI

struct WorkstationTerminalStartupModifier: ViewModifier {
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var sessionManager: SessionManager

    func body(content: Content) -> some View {
        content.onAppear {
            Task {
                await sessionManager.resizeTerminal(session: session, cols: 120, rows: 36)
            }
        }
    }
}
