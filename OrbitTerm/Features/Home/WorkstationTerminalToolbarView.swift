import SwiftUI

/// Session-level controls live above the terminal viewport so the viewport is
/// reserved for terminal content and its input bar.
struct WorkstationSessionContextBar: View {
    @Environment(\.appThemePalette) private var palette
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var sessionManager: SessionManager
    let isTerminalFullscreen: Bool
    let onToggleTerminalFullscreen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ConnectionProgressBanner(presentation: presentation)
                .font(.caption)

            Spacer(minLength: 8)

#if os(macOS)
            if session.isConnected, session.server.transport == .ssh {
                splitMenu
            }
            Button(action: onToggleTerminalFullscreen) {
                Label(
                    fullscreenLabel,
                    systemImage: isTerminalFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(fullscreenLabel)
            .accessibilityLabel(fullscreenLabel)
#endif
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(palette.surfaceGlassStrong.color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("终端会话状态：\(presentation.label)")
    }

    private var presentation: ConnectionPresentation {
        session.connectionPresentation
    }

    private var fullscreenLabel: String {
        let workspace = session.server.transport == .rdp ? "远程桌面" : "终端"
        return isTerminalFullscreen ? "退出\(workspace)全屏" : "\(workspace)全屏"
    }

#if os(macOS)
    private var splitMenu: some View {
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
        .menuStyle(.borderlessButton)
        .accessibilityLabel("终端分屏")
        .accessibilityHint("添加、移除或关闭终端分屏")
    }
#endif
}
