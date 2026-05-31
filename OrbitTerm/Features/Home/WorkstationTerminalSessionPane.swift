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

            WorkstationTerminalSessionHeaderView(session: session)

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
            .modifier(WorkstationTerminalStartupModifier(
                session: session,
                sessionManager: sessionManager,
                onSplitStateChanged: onSplitStateChanged
            ))

            Text("状态：\(session.terminalStatus)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
