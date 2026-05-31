import SwiftUI

struct WorkstationTerminalToolbarView: View {
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var sessionManager: SessionManager
    @Binding var isStressRunning: Bool
    let onSplitStateChanged: (Bool) -> Void
    let onToggleStress: (WorkspaceSession) -> Void

    var body: some View {
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
    }
}
