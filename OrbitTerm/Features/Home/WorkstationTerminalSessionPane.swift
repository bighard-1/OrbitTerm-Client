import SwiftUI

struct TerminalSessionPane: View {
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var sessionManager: SessionManager
    @Binding var isStressRunning: Bool
    let onSplitStateChanged: (Bool) -> Void
    let onToggleStress: (WorkspaceSession) -> Void
    @State private var showSearchOverlay = false
    @State private var searchText = ""
    @State private var searchCommand: TerminalSearchCommand?
    @State private var searchStatusText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkstationTerminalToolbarView(
                session: session,
                sessionManager: sessionManager,
                isStressRunning: $isStressRunning,
                onSplitStateChanged: onSplitStateChanged,
                onToggleStress: onToggleStress
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(session.server.name)
                    .font(.title3.weight(.semibold))
                Text("\(session.server.username)@\(session.server.endpointText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if showSearchOverlay {
                WorkstationTerminalSearchOverlay(
                    isPresented: $showSearchOverlay,
                    searchText: $searchText,
                    searchCommand: $searchCommand,
                    searchStatusText: $searchStatusText
                )
            }

            WorkstationTerminalSplitLayoutView(
                session: session,
                sessionManager: sessionManager,
                searchText: searchText,
                searchCommand: searchCommand,
                onSearchFeedback: { found, action in
                    switch action {
                    case .clear:
                        searchStatusText = "已清除搜索高亮"
                    case .next, .previous:
                        searchStatusText = found ? "已定位匹配项" : "未找到匹配项"
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .modifier(WorkstationTerminalDropUploadModifier(
                session: session,
                sessionManager: sessionManager
            ))
            .modifier(WorkstationTerminalSearchShortcutModifier(isPresented: $showSearchOverlay))
            .onAppear {
                Task {
                    onSplitStateChanged(session.terminalSplitCount > 0)
                    await sessionManager.ensureTerminalSplitChannels(session: session)
                    await sessionManager.resizeTerminal(session: session, cols: 120, rows: 36)
                }
            }

            Text("状态：\(session.terminalStatus)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
