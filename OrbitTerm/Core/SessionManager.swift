import Foundation

@MainActor
final class WorkspaceSession: ObservableObject, Identifiable {
    let id: UUID
    let server: ServerEntry

    @Published var terminalLines: [String]
    @Published var terminalStatus: String
    @Published var activeMonitorPanelID: UUID?
    @Published var isConnected: Bool

    let sftpManager: SFTPManager
    let dockerService: DockerService

    init(server: ServerEntry) {
        self.id = UUID()
        self.server = server
        self.terminalLines = ["欢迎使用 OrbitTerm 工作站"]
        self.terminalStatus = "未连接"
        self.activeMonitorPanelID = nil
        self.isConnected = false
        self.sftpManager = SFTPManager()
        self.dockerService = DockerService()
    }

    func appendTerminal(_ line: String) {
        terminalLines.append(line)
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

    private init() {}

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
            await tab.sftpManager.disconnect()
            await tab.dockerService.disconnect()
            if let panelID = tab.activeMonitorPanelID {
                await monitorService.disconnect(panelID)
            }
        }

        tabs.removeAll { $0.id == tab.id }
        if self.activeTabID == tab.id {
            self.activeTabID = tabs.first?.id
        }
    }

    func testConnection(session: WorkspaceSession) async {
        session.appendTerminal("[check] 正在测试连接 \(session.server.endpointText)")
        guard session.server.authMethod == .password else {
            session.appendTerminal("[warn] 密钥认证测试即将支持")
            return
        }

        let result = await orbitManager.testConnectionAsync(
            ip: session.server.host,
            username: session.server.username,
            password: session.server.password
        )
        session.appendTerminal("[check] \(result)")
    }

    func connect(session: WorkspaceSession) async {
        guard session.server.authMethod == .password else {
            session.terminalStatus = "当前版本仅支持密码认证自动连接"
            session.appendTerminal("[warn] 密钥认证自动连接暂未开放")
            return
        }

        session.terminalStatus = "连接中..."
        session.appendTerminal("[ssh] 正在连接 \(session.server.username)@\(session.server.endpointText)")

        await session.sftpManager.connect(
            host: session.server.host,
            username: session.server.username,
            password: session.server.password,
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

        session.activeMonitorPanelID = await monitorService.startMonitoring(
            name: session.server.name,
            host: session.server.host,
            username: session.server.username,
            password: session.server.password
        )

        await session.dockerService.connect(
            host: session.server.host,
            username: session.server.username,
            password: session.server.password
        )
        session.appendTerminal("[docker] \(session.dockerService.statusText)")
    }
}
