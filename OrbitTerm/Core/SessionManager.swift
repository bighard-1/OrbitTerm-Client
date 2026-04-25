import Foundation
import Combine

@MainActor
final class WorkspaceSession: ObservableObject, Identifiable {
    let id: UUID
    let server: ServerEntry

    @Published var terminalLines: [String]
    @Published var terminalStatus: String
    @Published var activeMonitorPanelID: UUID?
    @Published var isConnected: Bool
    @Published var terminalChannelID: UInt64?
    @Published var terminalInput: String

    let sftpManager: SFTPManager
    let dockerService: DockerService

    init(server: ServerEntry) {
        self.id = UUID()
        self.server = server
        self.terminalLines = ["欢迎使用 OrbitTerm 工作站"]
        self.terminalStatus = "未连接"
        self.activeMonitorPanelID = nil
        self.isConnected = false
        self.terminalChannelID = nil
        self.terminalInput = ""
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
            terminalLines.append(cleaned)
        }

        if terminalLines.count > 1200 {
            terminalLines.removeFirst(terminalLines.count - 1200)
        }
    }
}

@MainActor
final class SessionManager: ObservableObject {
    static let shared = SessionManager()

    @Published private(set) var tabs: [WorkspaceSession] = []
    @Published var activeTabID: UUID?
    @Published var quickOpenServer: ServerEntry?

    let monitorService = MonitorService()
    private let orbitManager = OrbitManager()
    private let credentialVault = CredentialVault.shared
    private let terminalService = TerminalService.shared
    private var sessionObservers: [UUID: AnyCancellable] = [:]
    private var monitorObserver: AnyCancellable?

    private init() {
        // 将监控服务的状态变化上抛到 SessionManager，保证主界面实时刷新。
        monitorObserver = monitorService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    var activeSession: WorkspaceSession? {
        guard let activeTabID else { return tabs.first }
        return tabs.first(where: { $0.id == activeTabID })
    }

    func session(for id: UUID?) -> WorkspaceSession? {
        guard let id else { return nil }
        return tabs.first(where: { $0.id == id })
    }

    func openTab(for server: ServerEntry, autoConnect: Bool = false) {
        if let existing = tabs.first(where: { $0.server.id == server.id }) {
            activeTabID = existing.id
            if autoConnect {
                Task { await connect(session: existing) }
            }
            return
        }

        let session = WorkspaceSession(server: server)
        bindSessionObservers(session)
        tabs.append(session)
        activeTabID = session.id

        if autoConnect {
            Task { await connect(session: session) }
        }
    }

    func openQuickTabFromSelection() {
        guard let quickOpenServer else { return }
        openTab(for: quickOpenServer, autoConnect: true)
    }

    func activateTab(_ id: UUID) {
        activeTabID = id
    }

    func activateIndex(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activeTabID = tabs[index].id
    }

    func closeActiveTab() {
        guard let activeTabID,
              let idx = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        closeTab(tabs[idx])
    }

    func closeTab(_ tab: WorkspaceSession) {
        Task {
            if let terminalID = tab.terminalChannelID {
                await terminalService.unbindAndClose(channelID: terminalID)
            }
            await tab.sftpManager.disconnect()
            await tab.dockerService.disconnect()
            if let panelID = tab.activeMonitorPanelID {
                await monitorService.disconnect(panelID)
            }
        }

        tabs.removeAll { $0.id == tab.id }
        sessionObservers.removeValue(forKey: tab.id)
        if self.activeTabID == tab.id {
            self.activeTabID = tabs.first?.id
        }
    }

    func testConnection(session: WorkspaceSession) async {
        session.appendTerminal("[check] 正在测试连接 \(session.server.endpointText)")

        guard let credentials = try? credentialVault.read(for: session.server.credentialID),
              !credentials.isEmpty else {
            session.appendTerminal("[error] 未找到该服务器凭据，请重新编辑凭据")
            return
        }

        let result = await orbitManager.testConnectionAsync(
            ip: session.server.host,
            port: session.server.port,
            username: session.server.username,
            password: credentials.password,
            privateKeyContent: credentials.privateKeyContent,
            privateKeyPassphrase: credentials.privateKeyPassphrase,
            allowPasswordFallback: session.server.allowPasswordFallback
        )
        session.appendTerminal("[check] \(result)")
    }

    func connect(session: WorkspaceSession) async {
        guard let credentials = try? credentialVault.read(for: session.server.credentialID),
              !credentials.isEmpty else {
            session.terminalStatus = "连接失败"
            session.appendTerminal("[error] 凭据不存在或已损坏，请重新保存服务器凭据")
            session.isConnected = false
            return
        }

        session.terminalStatus = "连接中..."
        session.appendTerminal("[ssh] 正在连接 \(session.server.username)@\(session.server.endpointText)")

        await session.sftpManager.connect(
            host: session.server.host,
            port: session.server.port,
            username: session.server.username,
            password: credentials.password,
            privateKeyContent: credentials.privateKeyContent,
            privateKeyPassphrase: credentials.privateKeyPassphrase,
            allowPasswordFallback: session.server.allowPasswordFallback,
            preferMock: false
        )

        guard session.sftpManager.isConnected, !session.sftpManager.isUsingMockData else {
            session.terminalStatus = "连接失败"
            session.appendTerminal("[error] \(session.sftpManager.statusText)")
            session.isConnected = false
            return
        }

        session.terminalStatus = "终端在线"
        session.isConnected = true
        session.appendTerminal("[ok] SSH 握手成功")

        if let oldTerminalID = session.terminalChannelID {
            await terminalService.unbindAndClose(channelID: oldTerminalID)
            session.terminalChannelID = nil
        }

        if let sftpChannelID = session.sftpManager.activeSessionID {
            if let terminalID = await terminalService.openPTY(sessionOrChannelID: sftpChannelID, cols: 120, rows: 36) {
                session.terminalChannelID = terminalID
                terminalService.bind(channelID: terminalID) { [weak session] (chunk: String) in
                    guard let session else { return }
                    session.appendTerminal(chunk)
                }
                session.appendTerminal("[pty] 交互终端已建立")
            } else {
                session.appendTerminal("[pty] 交互终端建立失败，当前仅保留监控/SFTP通道")
            }
        }

        session.activeMonitorPanelID = await monitorService.startMonitoring(
            name: session.server.name,
            host: session.server.host,
            port: session.server.port,
            username: session.server.username,
            credentials: credentials,
            allowPasswordFallback: session.server.allowPasswordFallback
        )

        await session.dockerService.connect(
            host: session.server.host,
            port: session.server.port,
            username: session.server.username,
            password: credentials.password,
            privateKeyContent: credentials.privateKeyContent,
            privateKeyPassphrase: credentials.privateKeyPassphrase,
            allowPasswordFallback: session.server.allowPasswordFallback
        )
        session.appendTerminal("[docker] \(session.dockerService.statusText)")
    }

    func sendTerminalInput(session: WorkspaceSession) async {
        guard let channelID = session.terminalChannelID else {
            session.appendTerminal("[pty] 当前未建立交互终端通道")
            return
        }
        let line = session.terminalInput
        session.terminalInput = ""
        let ok = await terminalService.write(channelID: channelID, text: line + "\n")
        if !ok {
            session.appendTerminal("[pty] 写入失败：终端通道不可用，正在尝试重连")
        }
    }

    func sendCtrlC(session: WorkspaceSession) async {
        guard let channelID = session.terminalChannelID else {
            session.appendTerminal("[pty] 当前未建立交互终端通道")
            return
        }
        _ = await terminalService.writeRaw(channelID: channelID, bytes: [3])
    }

    func resizeTerminal(session: WorkspaceSession, cols: Int, rows: Int) async {
        guard let channelID = session.terminalChannelID else { return }
        let safeCols = max(40, cols)
        let safeRows = max(12, rows)
        await terminalService.resize(channelID: channelID, cols: UInt32(safeCols), rows: UInt32(safeRows))
    }

    private func bindSessionObservers(_ session: WorkspaceSession) {
        let merged = Publishers.Merge3(
            session.objectWillChange,
            session.sftpManager.objectWillChange,
            session.dockerService.objectWillChange
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        sessionObservers[session.id] = merged
    }
}
