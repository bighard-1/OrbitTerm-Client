import SwiftUI

struct TerminalSessionPane: View {
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var sessionManager: SessionManager
    @AppStorage(TerminalThemeManager.storageKey) private var terminalThemeID: String = TerminalThemeManager.defaultThemeID
    @State private var showSearchOverlay = false
    @State private var searchText = ""
    @State private var searchCommand: TerminalSearchCommand?
    @State private var searchStatusText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkstationTerminalToolbarView(
                session: session,
                sessionManager: sessionManager
            )

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
            .background(
                TerminalThemeManager.theme(for: terminalThemeID).background.swiftUIColor,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .modifier(WorkstationTerminalDropUploadModifier(
                session: session,
                sessionManager: sessionManager
            ))
            .modifier(WorkstationTerminalSearchShortcutModifier(isPresented: $showSearchOverlay))
            .modifier(WorkstationTerminalStartupModifier(
                session: session,
                sessionManager: sessionManager
            ))
        }
    }
}
