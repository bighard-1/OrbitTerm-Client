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
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                TerminalThemeManager.theme(for: terminalThemeID).background.swiftUIColor,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            // The platform terminal view can draw its dirty region beyond a
            // SwiftUI sibling unless its viewport is explicitly clipped.
            // Keep the final terminal row inside this region so the command
            // preinput bar never obscures the cursor.
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .modifier(WorkstationTerminalDropUploadModifier(
                session: session,
                sessionManager: sessionManager
            ))
            .modifier(WorkstationTerminalSearchShortcutModifier(isPresented: $showSearchOverlay))
            .modifier(WorkstationTerminalStartupModifier(
                session: session,
                sessionManager: sessionManager
            ))
            .padding(.bottom, 2)

            TerminalCommandPreinputBar(
                session: session,
                sessionManager: sessionManager
            )
        }
    }
}

private struct TerminalCommandPreinputBar: View {
    @Environment(\.appThemePalette) private var palette
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var sessionManager: SessionManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(palette.textSecondary.color)
                .accessibilityHidden(true)

            TextField("预输入命令，按 Return 发送", text: $session.terminalInput)
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                .disabled(!session.isConnected)
                .onSubmit(send)
                .accessibilityLabel("终端命令预输入")
                .accessibilityHint("输入命令后按 Return 发送到当前终端")
#if os(macOS)
                .onKeyPress { keyPress in
                    guard keyPress.modifiers.contains(.control),
                          keyPress.characters.lowercased() == "c" else {
                        return .ignored
                    }
                    sendInterrupt()
                    return .handled
                }
#endif

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.accentPrimary.color)
            .disabled(!canSend)
            .accessibilityLabel("发送终端命令")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(palette.surfaceReadable.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.borderGlass.color, lineWidth: 1)
        }
    }

    private var canSend: Bool {
        session.isConnected && !session.terminalInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        Task { await sessionManager.sendTerminalInput(session: session) }
    }

    private func sendInterrupt() {
        guard session.isConnected else { return }
        Task { await sessionManager.sendCtrlC(session: session) }
    }
}
