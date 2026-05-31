import SwiftUI

struct WorkstationTerminalSessionHeaderView: View {
    @ObservedObject var session: WorkspaceSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.server.name)
                .font(.title3.weight(.semibold))
            Text("\(session.server.username)@\(session.server.endpointText)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

struct WorkstationTerminalStartupModifier: ViewModifier {
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var sessionManager: SessionManager
    let onSplitStateChanged: (Bool) -> Void

    func body(content: Content) -> some View {
        content.onAppear {
            Task {
                onSplitStateChanged(session.terminalSplitCount > 0)
                await sessionManager.ensureTerminalSplitChannels(session: session)
                await sessionManager.resizeTerminal(session: session, cols: 120, rows: 36)
            }
        }
    }
}
