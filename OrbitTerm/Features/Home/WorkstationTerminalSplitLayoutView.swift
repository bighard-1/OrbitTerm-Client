import SwiftUI

struct WorkstationTerminalSplitLayoutView: View {
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var sessionManager: SessionManager
    let searchText: String
    @Environment(\.appThemePalette) private var palette
    let searchCommand: TerminalSearchCommand?
    let onSearchFeedback: (Bool, TerminalSearchAction) -> Void

    var body: some View {
#if os(macOS)
        switch session.terminalSplitCount {
        case 0:
            terminalPane(index: 0)
        case 1:
            VStack(spacing: 8) {
                terminalPane(index: 0)
                terminalPane(index: 1)
            }
        case 2:
            VStack(spacing: 8) {
                terminalPane(index: 0)
                HStack(spacing: 8) {
                    terminalPane(index: 1)
                    terminalPane(index: 2)
                }
            }
        default:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    terminalPane(index: 0)
                    terminalPane(index: 1)
                }
                HStack(spacing: 8) {
                    terminalPane(index: 2)
                    terminalPane(index: 3)
                }
            }
        }
#else
        terminalPane(index: 0)
#endif
    }

    private func terminalPane(index: Int) -> some View {
        let paneChannelID = paneChannel(for: index)
        return SwiftTermTerminalView(
            channelID: paneChannelID,
            onResize: { cols, rows in
                guard let paneChannelID else { return }
                Task {
                    await sessionManager.resizeTerminal(
                        session: session,
                        cols: cols,
                        rows: rows,
                        channelID: paneChannelID
                    )
                }
            },
            onInput: { bytes in
                guard let paneChannelID else { return }
                session.activeTerminalPaneIndex = index
                sessionManager.enqueueTerminalInput(
                    session: session,
                    bytes: bytes,
                    channelID: paneChannelID
                )
            },
            searchText: searchText,
            searchCommand: searchCommand,
            focusRequest: session.activeTerminalPaneIndex == index
                ? session.terminalPaneFocusRequest
                : 0,
            onSearchFeedback: onSearchFeedback
        )
        .id("terminal-pane-\(session.id.uuidString)-\(index)-\(paneChannelID ?? 0)")
        .onTapGesture {
            session.activeTerminalPaneIndex = index
        }
        .overlay {
#if os(macOS)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    session.activeTerminalPaneIndex == index
                        ? palette.accentPrimary.color
                        : palette.borderGlass.color.opacity(0.55),
                    lineWidth: session.activeTerminalPaneIndex == index ? 1.5 : 1
                )
                .allowsHitTesting(false)
#endif
        }
#if os(macOS)
        .contextMenu {
            if index > 0 {
                Button("关闭此分屏", role: .destructive) {
                    Task {
                        await sessionManager.removeTerminalSplit(
                            session: session,
                            paneIndex: index
                        )
                    }
                }
            }
        }
        .accessibilityLabel("终端分屏 \(index + 1)\(session.activeTerminalPaneIndex == index ? "，当前" : "")")
#endif
    }

    private func paneChannel(for index: Int) -> UInt64? {
        if index < session.terminalChannelIDs.count {
            return session.terminalChannelIDs[index]
        }
        if index == 0 {
            return session.terminalChannelID
        }
        return nil
    }
}
