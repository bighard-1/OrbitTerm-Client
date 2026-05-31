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
            HStack {
                Text("终端会话")
                    .font(.headline)
                Spacer()
#if os(macOS)
                Button("分屏 +") {
                    Task { @MainActor in
                        session.terminalSplitCount = min(3, session.terminalSplitCount + 1)
                        onSplitStateChanged(session.terminalSplitCount > 0)
                        await sessionManager.ensureTerminalSplitChannels(session: session)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(session.terminalSplitCount >= 3)

                Button("合并 -") {
                    Task { @MainActor in
                        session.terminalSplitCount = max(0, session.terminalSplitCount - 1)
                        onSplitStateChanged(session.terminalSplitCount > 0)
                        await sessionManager.ensureTerminalSplitChannels(session: session)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(session.terminalSplitCount <= 0)
#endif

                Button("测试连接") {
                    Task { await sessionManager.testConnection(session: session) }
                }

                Button("连接") {
                    Task { await sessionManager.connect(session: session) }
                }
                .buttonStyle(.borderedProminent)

                Button("Ctrl+C") {
                    Task { await sessionManager.sendCtrlC(session: session) }
                }
                .buttonStyle(.bordered)

                Button(isStressRunning ? "停止压测" : "yes 压测") {
                    onToggleStress(session)
                }
                .buttonStyle(.bordered)
            }

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
