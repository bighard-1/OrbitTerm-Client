import Foundation

@MainActor
final class WorkstationStressController: ObservableObject {
    @Published var isRunning = false

    private var task: Task<Void, Never>?

    func toggle(for active: WorkspaceSession) {
        if isRunning {
            stop()
            active.appendTerminal("[stress] 压测已停止")
            return
        }

        isRunning = true
        active.appendTerminal("[stress] 开始 yes 字符流压测")

        let targetID = active.id
        task = Task.detached(priority: .utility) {
            var lineNo = 0
            while !Task.isCancelled {
                lineNo += 1
                let line = "yes yes yes yes | chunk \(lineNo)"
                await MainActor.run {
                    if let session = SessionManager.shared.session(for: targetID) {
                        session.appendTerminal(line)
                    }
                }
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}
