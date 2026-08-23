import Foundation
import Combine
import Network

struct TerminalLineEntry: Identifiable, Hashable {
    let id: UUID
    let text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

@MainActor
final class WorkspaceSession: ObservableObject, Identifiable {
    let id: UUID
    let server: ServerEntry

    @Published var terminalLines: [TerminalLineEntry]
    @Published var terminalStatus: String
    @Published var activeMonitorPanelID: UUID?
    @Published var isConnected: Bool
    @Published var terminalChannelID: UInt64?
    @Published var baseSessionID: UInt64?
    @Published var terminalInput: String
    @Published var commandHistory: [String]
    @Published var liveInputBuffer: String
    @Published var terminalSplitCount: Int
    @Published var terminalChannelIDs: [UInt64]
    @Published var activeTerminalPaneIndex: Int
    @Published var isTelnetSession: Bool
    @Published var verifiedSessionLease: VerifiedWorkspaceSession?

    let sftpManager: SFTPManager
    let dockerService: DockerService

    init(server: ServerEntry) {
        self.id = UUID()
        self.server = server
        self.terminalLines = [TerminalLineEntry(text: "欢迎使用 OrbitTerm 工作站")]
        self.terminalStatus = "未连接"
        self.activeMonitorPanelID = nil
        self.isConnected = false
        self.terminalChannelID = nil
        self.baseSessionID = nil
        self.terminalInput = ""
        self.commandHistory = []
        self.liveInputBuffer = ""
        self.terminalSplitCount = 0
        self.terminalChannelIDs = []
        self.activeTerminalPaneIndex = 0
        self.isTelnetSession = server.transport == .telnet
        self.verifiedSessionLease = nil
        self.sftpManager = SFTPManager()
        self.dockerService = DockerService()
    }

    func appendTerminal(_ line: String) {
        let normalized = line
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let parts = normalized.components(separatedBy: "\n")
        for part in parts {
            // 过滤无意义的 NUL 字符，避免终端渲染出现异常空行。
            let cleaned = part.replacingOccurrences(of: "\u{0000}", with: "")
            terminalLines.append(TerminalLineEntry(text: cleaned))
        }

        if terminalLines.count > 1200 {
            terminalLines.removeFirst(terminalLines.count - 1200)
        }
    }

    func captureTypedBytes(_ bytes: [UInt8]) -> [String] {
        guard !bytes.isEmpty else { return [] }
        var submittedCommands: [String] = []

        for byte in bytes {
            switch byte {
            case 10, 13:
                let command = liveInputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !command.isEmpty {
                    addCommandToHistory(command)
                    submittedCommands.append(command)
                }
                liveInputBuffer = ""
            case 8, 127:
                if !liveInputBuffer.isEmpty {
                    liveInputBuffer.removeLast()
                }
            case 0...31:
                continue
            default:
                if let scalar = UnicodeScalar(Int(byte)) {
                    liveInputBuffer.append(Character(scalar))
                }
            }
        }
        return submittedCommands
    }

    func addCommandToHistory(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if commandHistory.first == trimmed {
            return
        }
        commandHistory.removeAll(where: { $0 == trimmed })
        commandHistory.insert(trimmed, at: 0)
        if commandHistory.count > 100 {
            commandHistory.removeLast(commandHistory.count - 100)
        }
    }
}

extension WorkspaceSession: WorkspaceSessionPresenting {
    var presentationServerID: UUID { server.id }
}

extension WorkspaceSession: WorkspaceToolSession {
    var toolTransport: ServerTransportProtocol { server.transport }
    var toolHost: String { server.host }
    var toolPort: Int { server.port }
    var isSFTPConnected: Bool { sftpManager.isConnected }

    func configureToolConnection(
        policy: ConnectionSecurityPolicy,
        checkedDockerOperator: (any CheckedDockerOperating)?
    ) {
        sftpManager.configureConnectionMode(policy)
        dockerService.configureConnectionMode(policy, checkedOperator: checkedDockerOperator)
    }

    func openCheckedSFTP(
        baseSessionID: BaseSessionID,
        opener: any CheckedSFTPConnectionOpening
    ) async -> Result<CheckedSFTPConnection, CheckedSFTPServiceError> {
        await sftpManager.connectChecked(
            workspaceID: id,
            baseSessionID: baseSessionID,
            opener: opener,
            initialPath: SFTPInitialPathPolicy.preferredPath(username: server.username)
        )
    }

    func disconnectSFTP() async { await sftpManager.disconnect() }
    func rejectCheckedSFTP(_ error: CheckedSFTPServiceError) { sftpManager.rejectCheckedStandalone(error) }

    func startCheckedDocker(baseSessionID: BaseSessionID) async -> Result<Void, CheckedDockerServiceError> {
        await dockerService.startCheckedDocker(workspaceID: id, baseSessionID: baseSessionID)
    }

    func disconnectDocker() async { await dockerService.disconnect() }
    func rejectCheckedDocker(_ error: CheckedDockerServiceError) { dockerService.rejectCheckedStandalone(error) }
    func suspendDockerRefresh() async { await dockerService.suspendAutomaticRefresh() }
    func resumeDockerRefresh() async { await dockerService.resumeAutomaticRefresh() }
}
