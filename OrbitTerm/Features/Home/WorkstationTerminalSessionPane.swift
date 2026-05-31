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
    @FocusState private var isSearchFocused: Bool

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
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索终端历史", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSearchFocused)
                        .onSubmit { triggerSearch(.next) }

                    Button {
                        triggerSearch(.previous)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        triggerSearch(.next)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        searchText = ""
                        triggerSearch(.clear)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.bordered)

                    Button("关闭") {
                        showSearchOverlay = false
                        searchStatusText = ""
                    }
                    .buttonStyle(.bordered)
                }

                if !searchStatusText.isEmpty {
                    Text(searchStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
            .onAppear {
                Task {
                    onSplitStateChanged(session.terminalSplitCount > 0)
                    await sessionManager.ensureTerminalSplitChannels(session: session)
                    await sessionManager.resizeTerminal(session: session, cols: 120, rows: 36)
                }
            }
            .overlay(alignment: .topLeading) {
#if os(macOS)
                Button("") {
                    showSearchOverlay = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isSearchFocused = true
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0.001)
                .frame(width: 1, height: 1)
#endif
            }

            Text("状态：\(session.terminalStatus)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func triggerSearch(_ action: TerminalSearchAction) {
        searchCommand = TerminalSearchCommand(action: action)
    }
}
