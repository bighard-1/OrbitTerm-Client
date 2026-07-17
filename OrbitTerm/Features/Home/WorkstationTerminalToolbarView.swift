import SwiftUI

struct WorkstationTerminalToolbarView: View {
    @Environment(\.appThemePalette) private var palette
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var sessionManager: SessionManager

    var body: some View {
        HStack {
            Label(session.server.name, systemImage: "terminal")
                .font(.headline)
                .foregroundStyle(palette.textPrimary.color)
            Spacer()
#if os(macOS)
            if session.isConnected, !session.isTelnetSession {
                Menu {
                    Button("添加分屏") {
                        session.terminalSplitCount = min(3, session.terminalSplitCount + 1)
                        Task {
                            await sessionManager.ensureTerminalSplitChannels(session: session)
                        }
                    }
                    .disabled(session.terminalSplitCount >= 3)

                    Button("移除分屏") {
                        session.terminalSplitCount = max(0, session.terminalSplitCount - 1)
                        Task {
                            await sessionManager.ensureTerminalSplitChannels(session: session)
                        }
                    }
                    .disabled(session.terminalSplitCount == 0)

                    if session.terminalChannelIDs.count > 1 {
                        Divider()
                        ForEach(Array(session.terminalChannelIDs.indices.dropFirst()), id: \.self) { index in
                            Button("关闭分屏 \(index + 1)", role: .destructive) {
                                Task {
                                    await sessionManager.removeTerminalSplit(
                                        session: session,
                                        paneIndex: index
                                    )
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .foregroundStyle(palette.accentPrimary.color)
                }
                .accessibilityLabel("终端分屏")
                .accessibilityHint("添加或移除已验证终端会话的分屏")
            }
#endif
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("终端会话：\(session.server.name)")
    }
}
