import SwiftUI

struct DetachedSessionWindowView: View {
    let sessionID: UUID
    @ObservedObject private var sessionManager = SessionManager.shared

    var body: some View {
        Group {
            if let session = sessionManager.session(for: sessionID) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle().fill(session.isConnected ? Color.green : Color.gray).frame(width: 8, height: 8)
                        Text(session.server.name)
                            .font(.headline)
                        Spacer()
                        Text(session.terminalStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SwiftTermTerminalView(
                        channelID: session.terminalChannelID,
                        onResize: { cols, rows in
                            Task { await sessionManager.resizeTerminal(session: session, cols: cols, rows: rows) }
                        },
                        onInput: { bytes in
                            Task { await sessionManager.sendTerminalBytes(session: session, bytes: bytes) }
                        },
                        searchText: "",
                        searchCommand: nil,
                        onSearchFeedback: { _, _ in }
                    )
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(12)
            } else {
                ContentUnavailableView("会话已关闭", systemImage: "xmark.circle")
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}
