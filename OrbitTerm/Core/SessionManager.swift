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
    private var monitorObserver: AnyCancellable?
    private var connectionLostObserver: NSObjectProtocol?
    private var sessionByBaseID: [UInt64: UUID] = [:]
    private var telnetClients: [UUID: TelnetClient] = [:]

    private init() {
        // 将监控服务的状态变化上抛到 SessionManager，保证主界面实时刷新。
        monitorObserver = monitorService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        connectionLostObserver = NotificationCenter.default.addObserver(
            forName: .orbitConnectionLost,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let baseID = note.userInfo?["baseSessionID"] as? UInt64 else { return }
            Task { @MainActor in
                self.handleConnectionLost(baseSessionID: baseID)
            }
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
            await disconnect(session: tab)
        }

        tabs.removeAll { $0.id == tab.id }
        if let baseID = tab.baseSessionID {
            sessionByBaseID.removeValue(forKey: baseID)
        }
        telnetClients.removeValue(forKey: tab.id)
        if self.activeTabID == tab.id {
            self.activeTabID = tabs.first?.id
        }
    }

    func testConnection(session: WorkspaceSession) async {
        session.appendTerminal("[check] 正在测试连接 \(session.server.endpointText)")

        if session.server.transport == .telnet {
            let probe = TelnetClient(host: session.server.host, port: session.server.port)
            let credentials = try? credentialVault.read(for: session.server.credentialID)
            let autoLogin = TelnetClient.AutoLoginConfig(
                username: session.server.username,
                password: credentials?.password ?? "",
                profile: session.server.networkDeviceProfile
            )
            let ok = await probe.connect(autoLogin: autoLogin, onData: { _ in }, onState: { _ in })
            await probe.disconnect()
            session.appendTerminal(ok ? "[check] 成功: Telnet 端口可达，已尝试自动登录" : "[check] 失败: Telnet 连接不可达")
            return
        }

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
        if session.server.transport == .telnet {
            await connectTelnet(session: session)
            return
        }

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
        for extraID in session.terminalChannelIDs where extraID != session.terminalChannelID {
            await terminalService.unbindAndClose(channelID: extraID)
        }
        session.terminalChannelIDs = []
        session.activeTerminalPaneIndex = 0

        if let sftpChannelID = session.sftpManager.activeSessionID {
            if let baseID = terminalService.resolveBaseSessionID(sessionOrChannelID: sftpChannelID) {
                if let oldBase = session.baseSessionID, oldBase != baseID {
                    sessionByBaseID.removeValue(forKey: oldBase)
                }
                session.baseSessionID = baseID
                sessionByBaseID[baseID] = session.id
            }
            if let terminalID = await terminalService.openPTY(sessionOrChannelID: sftpChannelID, cols: 120, rows: 36) {
                session.terminalChannelID = terminalID
                session.terminalChannelIDs = [terminalID]
                session.activeTerminalPaneIndex = 0
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

    private func connectTelnet(session: WorkspaceSession) async {
        session.terminalStatus = "连接中..."
        session.appendTerminal("[telnet] 正在连接 \(session.server.username)@\(session.server.endpointText)")
        session.isConnected = false

        if let old = telnetClients[session.id] {
            await old.disconnect()
            telnetClients.removeValue(forKey: session.id)
        }
        if let oldTerminalID = session.terminalChannelID {
            await terminalService.unbindAndClose(channelID: oldTerminalID)
            session.terminalChannelID = nil
        }
        session.terminalChannelIDs = []
        session.activeTerminalPaneIndex = 0
        session.baseSessionID = nil
        session.isTelnetSession = true

        let credentials = try? credentialVault.read(for: session.server.credentialID)
        let autoLogin = TelnetClient.AutoLoginConfig(
            username: session.server.username,
            password: credentials?.password ?? "",
            profile: session.server.networkDeviceProfile
        )
        let client = TelnetClient(host: session.server.host, port: session.server.port)
        let virtualChannelID = await terminalService.createVirtualChannel { [weak self, weak client] bytes in
            guard self != nil, let client else { return false }
            return await client.send(bytes)
        }

        let ok = await client.connect(
            autoLogin: autoLogin,
            onData: { [weak self] (data: Data) in
                guard let self else { return }
                Task {
                    await self.terminalService.feedVirtualChannel(channelID: virtualChannelID, data: data)
                }
            },
            onState: { [weak session] (state: TelnetClient.State) in
                guard let session else { return }
                Task { @MainActor in
                    switch state {
                    case .connecting:
                        session.terminalStatus = "连接中..."
                    case .connected:
                        session.terminalStatus = "终端在线"
                    case .closed:
                        session.terminalStatus = "连接已断开"
                        session.isConnected = false
                    case let .failed(msg):
                        session.terminalStatus = "连接失败"
                        session.appendTerminal("[telnet] 连接异常: \(msg)")
                        session.isConnected = false
                    case .idle:
                        break
                    }
                }
            }
        )

        guard ok else {
            await terminalService.unbindAndClose(channelID: virtualChannelID)
            session.terminalStatus = "连接失败"
            session.appendTerminal("[telnet] 连接失败")
            return
        }

        telnetClients[session.id] = client
        session.terminalChannelID = virtualChannelID
        session.terminalChannelIDs = [virtualChannelID]
        session.activeTerminalPaneIndex = 0
        session.isConnected = true
        session.terminalStatus = "终端在线"
        session.appendTerminal("[ok] Telnet 通道已建立")
        if autoLogin.isEnabled {
            session.appendTerminal("[telnet] 已启用 \(session.server.networkDeviceProfile.displayName) 自动登录模板")
        } else {
            session.appendTerminal("[telnet] 未找到密码，保留手动登录模式")
        }
        session.appendTerminal("[tip] Telnet 为明文协议，仅建议在可信内网临时使用")
    }

    func sendTerminalInput(session: WorkspaceSession) async {
        guard let channelID = resolveChannelID(session: session, preferred: nil) else {
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
        guard let channelID = resolveChannelID(session: session, preferred: nil) else {
            session.appendTerminal("[pty] 当前未建立交互终端通道")
            return
        }
        _ = await terminalService.writeRaw(channelID: channelID, bytes: [3])
    }

    func sendTerminalBytes(session: WorkspaceSession, bytes: [UInt8], channelID: UInt64? = nil) async {
        guard let targetChannelID = resolveChannelID(session: session, preferred: channelID) else { return }
        let submitted = session.captureTypedBytes(bytes)
        _ = await terminalService.writeRaw(channelID: targetChannelID, bytes: bytes)
        if !submitted.isEmpty {
            await syncSFTPPathIfNeeded(session: session, submittedCommands: submitted)
        }
    }

    func dispatchSnippetCommand(session: WorkspaceSession, command: String, executeImmediately: Bool) async {
        guard let channelID = resolveChannelID(session: session, preferred: nil) else {
            session.appendTerminal("[snippet] 终端未连接，无法插入命令")
            return
        }
        let payload = executeImmediately ? command + "\n" : command
        let bytes = Array(payload.utf8)
        let submitted = session.captureTypedBytes(bytes)
        if executeImmediately {
            session.addCommandToHistory(command)
        }
        _ = await terminalService.writeRaw(channelID: channelID, bytes: bytes)
        if !submitted.isEmpty {
            await syncSFTPPathIfNeeded(session: session, submittedCommands: submitted)
        }
    }

    func resizeTerminal(session: WorkspaceSession, cols: Int, rows: Int, channelID: UInt64? = nil) async {
        guard let targetChannelID = resolveChannelID(session: session, preferred: channelID) else { return }
        let safeCols = max(40, cols)
        let safeRows = max(12, rows)
        await terminalService.resize(channelID: targetChannelID, cols: UInt32(safeCols), rows: UInt32(safeRows))
    }

    func ensureTerminalSplitChannels(session: WorkspaceSession) async {
        if session.server.transport == .telnet {
            session.terminalSplitCount = 0
            return
        }
        guard session.isConnected,
              let baseID = session.baseSessionID else {
            return
        }
        let desired = max(1, min(4, session.terminalSplitCount + 1))
        while session.terminalChannelIDs.count < desired {
            guard let newChannelID = await terminalService.openPTY(sessionOrChannelID: baseID, cols: 120, rows: 36) else {
                session.appendTerminal("[pty] 新分屏创建失败")
                break
            }
            session.terminalChannelIDs.append(newChannelID)
        }
        while session.terminalChannelIDs.count > desired {
            if let removed = session.terminalChannelIDs.popLast() {
                await terminalService.unbindAndClose(channelID: removed)
            }
        }
        if session.terminalChannelIDs.isEmpty, let fallback = session.terminalChannelID {
            session.terminalChannelIDs = [fallback]
        }
        session.activeTerminalPaneIndex = min(session.activeTerminalPaneIndex, max(0, session.terminalChannelIDs.count - 1))
        session.terminalChannelID = session.terminalChannelIDs.first
    }

    func syncTerminalPathFromSFTP(session: WorkspaceSession, newPath: String) async {
        guard session.terminalSplitCount == 0 else { return }
        guard let channelID = resolveChannelID(session: session, preferred: nil) else { return }
        let escaped = "'" + newPath.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let command = "cd \(escaped)\n"
        _ = await terminalService.writeRaw(channelID: channelID, bytes: Array(command.utf8))
    }

    private func handleConnectionLost(baseSessionID: UInt64) {
        guard let workspaceID = sessionByBaseID[baseSessionID],
              let session = tabs.first(where: { $0.id == workspaceID }) else {
            return
        }

        session.isConnected = false
        session.terminalStatus = "连接已断开，点击重连"
        session.appendTerminal("[ssh] 连接已断开（心跳超时），请点击“连接”重试")
    }

    private func syncSFTPPathIfNeeded(session: WorkspaceSession, submittedCommands: [String]) async {
        guard session.server.transport == .ssh else { return }
        guard session.terminalSplitCount == 0 else { return }
        guard session.isConnected, session.sftpManager.isConnected else { return }
        for command in submittedCommands {
            guard let nextPath = resolvePathFromShellCommand(
                command: command,
                currentPath: session.sftpManager.currentPath,
                username: session.server.username
            ) else {
                continue
            }
            if await session.sftpManager.goToPath(nextPath, reportErrors: false) {
                continue
            }
            for fallback in fallbackPaths(for: nextPath, username: session.server.username) {
                if await session.sftpManager.goToPath(fallback, reportErrors: false) {
                    break
                }
            }
        }
    }

    private func resolvePathFromShellCommand(command: String, currentPath: String, username: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 仅提取首段命令（支持 `cd /a && ls`、`cd /a; pwd` 等）。
        let firstSegment = trimmed
            .components(separatedBy: "&&").first?
            .components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed

        guard firstSegment == "cd" || firstSegment.hasPrefix("cd ") else { return nil }

        let rawArg = String(firstSegment.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        if rawArg.isEmpty {
            return nil
        }

        let unquoted: String
        if (rawArg.hasPrefix("'") && rawArg.hasSuffix("'")) || (rawArg.hasPrefix("\"") && rawArg.hasSuffix("\"")) {
            unquoted = String(rawArg.dropFirst().dropLast())
        } else {
            unquoted = rawArg
        }

        if unquoted.isEmpty {
            return nil
        }

        let unescaped = unquoted
            .replacingOccurrences(of: "\\ ", with: " ")
            .replacingOccurrences(of: "\\(", with: "(")
            .replacingOccurrences(of: "\\)", with: ")")

        let merged: String
        if unescaped == "-" {
            return nil
        } else if unescaped == "~" {
            merged = username == "root" ? "/root" : "/home/\(username)"
        } else if unescaped.hasPrefix("~/") {
            let home = username == "root" ? "/root" : "/home/\(username)"
            merged = home + "/" + String(unescaped.dropFirst(2))
        } else if unescaped.hasPrefix("/") {
            merged = unescaped
        } else {
            let base = currentPath == "/" ? "" : currentPath
            merged = "\(base)/\(unescaped)"
        }
        return normalizePath(merged)
    }

    private func normalizePath(_ path: String) -> String {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        var stack: [Substring] = []
        for comp in comps {
            if comp == "." {
                continue
            } else if comp == ".." {
                if !stack.isEmpty { stack.removeLast() }
            } else {
                stack.append(comp)
            }
        }
        return "/" + stack.joined(separator: "/")
    }

    private func resolveChannelID(session: WorkspaceSession, preferred: UInt64?) -> UInt64? {
        if let preferred {
            return preferred
        }
        if !session.terminalChannelIDs.isEmpty {
            let idx = min(session.activeTerminalPaneIndex, session.terminalChannelIDs.count - 1)
            return session.terminalChannelIDs[idx]
        }
        return session.terminalChannelID
    }

    private func fallbackPaths(for resolvedPath: String, username: String) -> [String] {
        var list: [String] = []
        if username == "root", resolvedPath.hasPrefix("/home/root/") {
            list.append(resolvedPath.replacingOccurrences(of: "/home/root/", with: "/root/"))
        } else if username != "root", resolvedPath.hasPrefix("/root/") {
            list.append(resolvedPath.replacingOccurrences(of: "/root/", with: "/home/\(username)/"))
        }
        return list.map(normalizePath)
    }

    func disconnect(session: WorkspaceSession) async {
        if session.server.transport == .telnet {
            if let client = telnetClients[session.id] {
                await client.disconnect()
                telnetClients.removeValue(forKey: session.id)
            }
            let ids = session.terminalChannelIDs.isEmpty ? (session.terminalChannelID.map { [$0] } ?? []) : session.terminalChannelIDs
            for id in ids {
                await terminalService.unbindAndClose(channelID: id)
            }
            session.terminalChannelIDs = []
            session.terminalChannelID = nil
            session.isConnected = false
            session.terminalStatus = "未连接"
            return
        }
        let ids = session.terminalChannelIDs.isEmpty ? (session.terminalChannelID.map { [$0] } ?? []) : session.terminalChannelIDs
        for id in ids {
            await terminalService.unbindAndClose(channelID: id)
        }
        await session.sftpManager.disconnect()
        await session.dockerService.disconnect()
        if let panelID = session.activeMonitorPanelID {
            await monitorService.disconnect(panelID)
        }
        session.terminalChannelIDs = []
        session.terminalChannelID = nil
        session.isConnected = false
        session.terminalStatus = "未连接"
    }
}
