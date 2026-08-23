import Foundation
import Combine
import Network

struct RemoteProcessSnapshot: Identifiable, Hashable, Sendable {
    let pid: Int
    let parentPID: Int
    let user: String
    let cpuPercent: Double
    let memoryPercent: Double
    let elapsedSeconds: Int
    let state: String
    let command: String

    var id: Int { pid }
}

enum RemoteProcessMonitorError: Error, LocalizedError {
    case requiresVerifiedSession
    case commandFailed(String)
    case invalidProcess
    case protectedProcess
    case identityChanged

    var errorDescription: String? {
        switch self {
        case .requiresVerifiedSession: "需要已验证的 SSH 会话"
        case let .commandFailed(message): message
        case .invalidProcess: "进程信息无效，操作已取消"
        case .protectedProcess: "系统关键进程不允许在此处终止"
        case .identityChanged: "进程身份已经变化，请刷新后重试"
        }
    }
}

@MainActor
final class SessionManager: ObservableObject {
    static let shared = SessionManager()

    @Published var quickOpenServer: ServerEntry?
    @Published private(set) var checkedHostKeyRoute: CheckedHostKeyPresentationRoute?
    @Published private(set) var telnetRiskRoute: TelnetRiskPresentationRoute?

    let monitorService: MonitorService
    private let workspacePresentation = WorkspacePresentationCoordinator<WorkspaceSession>()
    private var workspacePresentationObserver: AnyCancellable?
    #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
    private let orbitManager = OrbitManager()
    #endif
    private let credentialVault = CredentialVault.shared
    private let terminalService = TerminalService.shared
    private let checkedConnectionDispatcher: SessionConnectionDispatcher
    private let checkedClient: any CheckedFFIClient
    private let checkedSFTPService: any CheckedSFTPConnectionOpening
    private let checkedDockerService: any CheckedDockerOperating
    private let workspaceToolCoordinator: WorkspaceToolCoordinator
    private let telnetAccessPolicy: TelnetAccessPolicy
    private var monitorObserver: AnyCancellable?
    private var connectionLostObserver: NSObjectProtocol?
    private var sessionByBaseID: [UInt64: UUID] = [:]
    private var telnetClients: [UUID: TelnetClient] = [:]
    private var auxiliaryRefreshTask: Task<Void, Never>?
    private var auxiliaryRefreshOwner = OperationOwner()
    private var auxiliaryRefreshesAreActive = true

    private init(
        connectionSecurityPolicy: ConnectionSecurityPolicy = .applicationDefault,
        checkedClient: (any CheckedFFIClient)? = nil,
        telnetAccessPolicy: TelnetAccessPolicy? = nil
    ) {
        checkedConnectionDispatcher = SessionConnectionDispatcher(policy: connectionSecurityPolicy)
        self.telnetAccessPolicy = telnetAccessPolicy ?? .shared
        let resolvedCheckedClient = checkedClient ?? OrbitCoreCheckedFFIClient.live(
            credentialProvider: CredentialVaultCheckedProvider()
        )
        self.checkedClient = resolvedCheckedClient
        checkedSFTPService = CheckedSFTPConnectionService(client: resolvedCheckedClient)
        checkedDockerService = CheckedDockerOperationService(client: resolvedCheckedClient)
        monitorService = MonitorService(
            connectionMode: connectionSecurityPolicy,
            checkedSnapshotService: CheckedMonitorSnapshotService(client: resolvedCheckedClient)
        )
        workspaceToolCoordinator = WorkspaceToolCoordinator(
            policy: connectionSecurityPolicy,
            sftpOpener: checkedSFTPService,
            dockerOperator: checkedDockerService,
            monitoring: monitorService
        )
        // 将监控服务与 workspace presentation 的状态变化上抛到
        // SessionManager，保持既有 View 的观察入口稳定。
        monitorObserver = monitorService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        workspacePresentationObserver = workspacePresentation.objectWillChange
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

    var tabs: [WorkspaceSession] { workspacePresentation.tabs }

    var activeTabID: UUID? { workspacePresentation.activeTabID }

    var activeSession: WorkspaceSession? { workspacePresentation.activeSession }


    var requiresCheckedConnection: Bool {
        checkedConnectionDispatcher.path == .checked
    }

    var connectionSecurityPolicy: ConnectionSecurityPolicy {
        checkedConnectionDispatcher.policy
    }

    func session(for id: UUID?) -> WorkspaceSession? {
        workspacePresentation.session(for: id)
    }

    func verifiedSessionLease(for serverID: UUID) -> VerifiedWorkspaceSession? {
        workspacePresentation.session(forServerID: serverID)?.verifiedSessionLease
    }

    /// Batch execution may establish a previously trusted asset with its saved
    /// credential, but it must never turn an unknown/changed host key into an
    /// implicit trust decision. A per-target reason lets the batch continue
    /// without presenting a blocking confirmation dialog for every asset.
    func prepareVerifiedSessionForBatch(server: ServerEntry) async -> String? {
        if verifiedSessionLease(for: server.id) != nil { return nil }
        let previousActiveID = activeTabID
        openTab(for: server, autoConnect: false)
        guard let workspace = workspacePresentation.session(forServerID: server.id) else {
            return "无法创建资产会话"
        }
        await connect(session: workspace)
        if checkedHostKeyRoute?.workspaceID == workspace.id {
            let reason = workspace.terminalStatus == "等待服务器身份确认"
                ? "需要先单独连接并确认服务器身份"
                : workspace.terminalStatus
            cancelCheckedHostKeyFlow()
            if let previousActiveID { activateTab(previousActiveID) }
            return reason
        }
        if let previousActiveID { activateTab(previousActiveID) }
        guard workspace.verifiedSessionLease != nil else {
            return workspace.terminalStatus.isEmpty ? "凭据无效或网络连接失败" : workspace.terminalStatus
        }
        return nil
    }

    func fetchRemoteProcesses(session: WorkspaceSession) async throws -> [RemoteProcessSnapshot] {
        guard session.isConnected, let lease = session.verifiedSessionLease else {
            throw RemoteProcessMonitorError.requiresVerifiedSession
        }
        let service = CheckedBatchCommandService(client: checkedClient)
        let target = CheckedBatchTarget(
            workspaceID: session.id,
            displayName: session.server.name,
            endpoint: "\(session.server.host):\(session.server.port)",
            baseSessionID: lease.baseSessionID
        )
        let command = "LC_ALL=C ps -eo pid=,ppid=,user=,pcpu=,pmem=,etimes=,stat=,comm= --sort=-pcpu | head -n 257"
        guard let result = await service.execute(command: command, targets: [target]).first else {
            throw RemoteProcessMonitorError.commandFailed("无法读取远端进程")
        }
        guard result.succeeded else {
            throw RemoteProcessMonitorError.commandFailed(result.error?.userMessage ?? "无法读取远端进程")
        }
        return result.stdout.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(maxSplits: 7, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard columns.count == 8,
                  let pid = Int(columns[0]),
                  let parentPID = Int(columns[1]),
                  let cpu = Double(columns[3]),
                  let memory = Double(columns[4]),
                  let elapsed = Int(columns[5]) else {
                return nil
            }
            return RemoteProcessSnapshot(
                pid: pid,
                parentPID: parentPID,
                user: String(columns[2]),
                cpuPercent: cpu,
                memoryPercent: memory,
                elapsedSeconds: elapsed,
                state: String(columns[6]),
                command: String(columns[7])
            )
        }
    }

    func terminateRemoteProcess(
        _ process: RemoteProcessSnapshot,
        session: WorkspaceSession,
        force: Bool = false
    ) async throws {
        guard session.isConnected, let lease = session.verifiedSessionLease else {
            throw RemoteProcessMonitorError.requiresVerifiedSession
        }
        guard process.pid > 1,
              process.command.range(of: #"^[A-Za-z0-9._:+-]+$"#, options: .regularExpression) != nil else {
            throw RemoteProcessMonitorError.invalidProcess
        }
        let protectedNames: Set<String> = ["init", "systemd", "sshd", "kernel_task", "launchd"]
        guard !protectedNames.contains(process.command.lowercased()) else {
            throw RemoteProcessMonitorError.protectedProcess
        }
        let signal = force ? "KILL" : "TERM"
        let command = "actual=$(LC_ALL=C ps -p \(process.pid) -o comm= | tr -d '[:space:]'); [ \"$actual\" = '\(process.command)' ] || exit 73; kill -\(signal) \(process.pid)"
        let service = CheckedBatchCommandService(client: checkedClient)
        let target = CheckedBatchTarget(
            workspaceID: session.id,
            displayName: session.server.name,
            endpoint: "\(session.server.host):\(session.server.port)",
            baseSessionID: lease.baseSessionID
        )
        guard let result = await service.execute(command: command, targets: [target]).first else {
            throw RemoteProcessMonitorError.commandFailed("终止进程失败")
        }
        if result.exitStatus == 73 {
            throw RemoteProcessMonitorError.identityChanged
        }
        guard result.succeeded else {
            throw RemoteProcessMonitorError.commandFailed(result.error?.userMessage ?? "终止进程失败")
        }
    }

    func openTab(for server: ServerEntry, autoConnect: Bool = false) {
        if let existing = workspacePresentation.session(forServerID: server.id) {
            activateTab(existing.id)
            // Selecting an already open session must not rebuild a healthy
            // connection. A repeated sidebar click while its checked route is
            // awaiting a decision must likewise leave that single route intact.
            if autoConnect,
               !existing.isConnected,
               checkedHostKeyRoute?.workspaceID != existing.id {
                Task { await connect(session: existing) }
            }
            return
        }

        let session = WorkspaceSession(server: server)
        workspaceToolCoordinator.configure(session)
        let previousSession = workspacePresentation.appendAndActivate(session)
        scheduleAuxiliaryRefreshTransition(
            suspending: previousSession,
            resuming: auxiliaryRefreshesAreActive ? session : nil
        )

        if autoConnect {
            Task { await connect(session: session) }
        }
    }

    func openQuickTabFromSelection() {
        guard let quickOpenServer else { return }
        openTab(for: quickOpenServer, autoConnect: true)
    }

    func activateTab(_ id: UUID) {
        guard let previousSession = workspacePresentation.activate(id) else { return }
        scheduleAuxiliaryRefreshTransition(
            suspending: previousSession,
            resuming: auxiliaryRefreshesAreActive ? activeSession : nil
        )
    }

    func activateIndex(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activateTab(tabs[index].id)
    }

    /// Keeps background polling tied to the visible, unlocked workspace while
    /// preserving existing SSH, terminal, and SFTP connection lifecycles.
    func setAuxiliaryRefreshesActive(_ isActive: Bool) {
        guard auxiliaryRefreshesAreActive != isActive else { return }
        auxiliaryRefreshesAreActive = isActive
        if isActive {
            let activeID = activeSession?.id
            scheduleAuxiliaryRefreshTransition(
                suspending: tabs.filter { $0.id != activeID },
                resuming: activeSession
            )
        } else {
            scheduleAuxiliaryRefreshTransition(suspending: tabs, resuming: nil)
        }
    }

    func closeActiveTab() {
        guard let activeTabID,
              let idx = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        closeTab(tabs[idx])
    }

    /// Account changes must never leave an authenticated terminal tab visible.
    /// Reuse the existing per-tab teardown path so SSH, SFTP, Docker and Monitor
    /// resources follow their normal disconnect order.
    func closeAllTabs() {
        let currentTabs = tabs
        for tab in currentTabs {
            closeTab(tab)
        }
    }

    func closeTab(_ tab: WorkspaceSession) {
        if checkedHostKeyRoute?.workspaceID == tab.id {
            _ = checkedHostKeyRoute?.orchestrator.cancel()
            checkedHostKeyRoute = nil
        }
        if telnetRiskRoute?.workspaceID == tab.id {
            telnetRiskRoute = nil
        }
        Task {
            await disconnect(session: tab)
        }

        let removedWasActive = workspacePresentation.remove(tab.id)
        if let baseID = tab.baseSessionID {
            sessionByBaseID.removeValue(forKey: baseID)
        }
        telnetClients.removeValue(forKey: tab.id)
        if removedWasActive {
            scheduleAuxiliaryRefreshTransition(
                suspending: nil,
                resuming: auxiliaryRefreshesAreActive ? activeSession : nil
            )
        }
    }

    private func scheduleAuxiliaryRefreshTransition(
        suspending session: WorkspaceSession?,
        resuming nextSession: WorkspaceSession?
    ) {
        scheduleAuxiliaryRefreshTransition(
            suspending: session.map { [$0] } ?? [],
            resuming: nextSession
        )
    }

    private func scheduleAuxiliaryRefreshTransition(
        suspending sessions: [WorkspaceSession],
        resuming nextSession: WorkspaceSession?
    ) {
        auxiliaryRefreshTask?.cancel()
        let lease = auxiliaryRefreshOwner.begin()
        auxiliaryRefreshTask = Task { [weak self] in
            guard let self else { return }
            for session in sessions {
                await self.suspendAuxiliaryRefreshes(for: session)
                guard !Task.isCancelled, self.auxiliaryRefreshOwner.owns(lease) else { return }
            }
            guard let nextSession,
                  self.auxiliaryRefreshesAreActive,
                  !Task.isCancelled,
                  self.auxiliaryRefreshOwner.owns(lease) else {
                return
            }
            await self.resumeAuxiliaryRefreshes(for: nextSession)
            guard !Task.isCancelled, self.auxiliaryRefreshOwner.owns(lease) else { return }
            self.auxiliaryRefreshTask = nil
        }
    }

    private func suspendAuxiliaryRefreshes(for session: WorkspaceSession) async {
        await workspaceToolCoordinator.suspendAuxiliaryRefreshes(for: session)
    }

    private func resumeAuxiliaryRefreshes(for session: WorkspaceSession) async {
        await workspaceToolCoordinator.resumeAuxiliaryRefreshes(for: session)
    }

    func testConnection(session: WorkspaceSession) async {
        session.appendTerminal("[check] 正在测试连接 \(session.server.endpointText)")

        guard checkedConnectionDispatcher.policy.allowsLegacyNetwork else {
            session.appendTerminal("[check] 独立连接测试已停用，请使用“连接”完成服务器身份验证")
            return
        }

        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
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
        #else
        session.appendTerminal("[check] 独立连接测试在此构建中不可用")
        #endif
    }

    func openSFTPForActiveSessionIfNeeded(standaloneManager: SFTPManager) async {
        standaloneManager.configureConnectionMode(checkedConnectionDispatcher.policy)
        guard let active = activeSession else {
            if requiresCheckedConnection {
                standaloneManager.rejectCheckedStandalone()
            }
            return
        }
        await openSFTPIfNeeded(for: active)
    }

    private func openSFTPIfNeeded(for session: WorkspaceSession) async {
        if await workspaceToolCoordinator.openSFTPIfHandled(for: session) { return }
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        guard session.isConnected,
              let credentials = try? credentialVault.read(for: session.server.credentialID),
              !credentials.isEmpty else {
            return
        }
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
        #else
        session.sftpManager.rejectCheckedStandalone(.legacySFTPDisabledInCheckedMode)
        #endif
    }

    func startMonitorForActiveSessionIfNeeded() async {
        guard let active = activeSession else { return }
        await startMonitorIfNeeded(for: active)
    }

    private func startMonitorIfNeeded(for session: WorkspaceSession) async {
        _ = await workspaceToolCoordinator.startMonitorIfHandled(for: session, name: session.server.name)
    }

    func startDockerForActiveSessionIfNeeded() async {
        guard let active = activeSession else { return }
        await startDockerIfNeeded(for: active)
    }

    private func startDockerIfNeeded(for session: WorkspaceSession) async {
        _ = await workspaceToolCoordinator.startDockerIfHandled(for: session)
    }

    func connect(session: WorkspaceSession) async {
        if session.server.transport == .telnet {
            let target = TelnetTargetIdentity(
                serverID: session.server.id,
                host: session.server.host,
                port: session.server.port
            )
            switch telnetAccessPolicy.decision(for: target) {
            case .preferenceDisabled:
                rejectDisabledTelnet(session: session)
            case .requiresConfirmation:
                requestTelnetRiskConfirmation(session: session, target: target)
            case .allowed:
                await connectTelnet(session: session)
            }
            return
        }

        workspaceToolCoordinator.configure(session)

        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        if checkedConnectionDispatcher.policy.allowsLegacyNetwork {
            await connectLegacyInternal(session: session)
            return
        }
        #endif

        await connectChecked(session: session)
    }

    #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
    private func connectLegacyInternal(session: WorkspaceSession) async {
        guard let credentials = try? credentialVault.read(for: session.server.credentialID),
              !credentials.isEmpty else {
            session.terminalStatus = "连接失败"
            session.appendTerminal("[error] 凭据不存在或已损坏，请重新保存服务器凭据")
            session.isConnected = false
            return
        }

        if session.baseSessionID != nil || session.terminalChannelID != nil ||
            !session.terminalChannelIDs.isEmpty || session.sftpManager.isConnected ||
            session.dockerService.isConnected {
            session.appendTerminal("[ssh] 正在重建连接，先清理旧通道")
            await disconnect(session: session)
        }

        session.terminalStatus = "连接中..."
        session.appendTerminal("[ssh] 正在连接 \(session.server.username)@\(session.server.endpointText)")
        guard let baseID = await terminalService.openSSHSession(
            host: session.server.host,
            port: session.server.port,
            username: session.server.username,
            password: credentials.password,
            privateKeyContent: credentials.privateKeyContent,
            privateKeyPassphrase: credentials.privateKeyPassphrase,
            allowPasswordFallback: session.server.allowPasswordFallback
        ) else {
            session.terminalStatus = "连接失败"
            session.appendTerminal("[error] SSH 连接失败，请检查主机、端口、用户名或凭据")
            session.isConnected = false
            return
        }

        session.terminalStatus = "终端在线"
        session.isConnected = true
        session.appendTerminal("[ok] SSH 握手成功")
        if let oldBase = session.baseSessionID, oldBase != baseID {
            sessionByBaseID.removeValue(forKey: oldBase)
        }
        session.baseSessionID = baseID
        sessionByBaseID[baseID] = session.id

        if let oldTerminalID = session.terminalChannelID {
            await terminalService.unbindAndClose(channelID: oldTerminalID)
            session.terminalChannelID = nil
        }
        for extraID in session.terminalChannelIDs where extraID != session.terminalChannelID {
            await terminalService.unbindAndClose(channelID: extraID)
        }
        session.terminalChannelIDs = []
        session.activeTerminalPaneIndex = 0

        if let terminalID = await terminalService.openPTY(sessionOrChannelID: baseID, cols: 120, rows: 36) {
            session.terminalChannelID = terminalID
            session.terminalChannelIDs = [terminalID]
            session.appendTerminal("[pty] 交互终端已建立")
        } else {
            session.appendTerminal("[pty] 交互终端建立失败，SFTP/Docker/监控将继续尝试")
        }

        await session.sftpManager.connect(baseSessionID: baseID)
        session.activeMonitorPanelID = await monitorService.startMonitoring(
            name: session.server.name,
            host: session.server.host,
            port: session.server.port,
            username: session.server.username,
            credentials: credentials,
            allowPasswordFallback: session.server.allowPasswordFallback,
            baseSessionID: baseID
        )
        await session.dockerService.connect(baseSessionID: baseID)
    }
    #endif

    private func connectChecked(session: WorkspaceSession) async {
        guard checkedHostKeyRoute == nil else {
            session.terminalStatus = "等待其他身份确认完成"
            session.isConnected = false
            session.appendTerminal("[checked] 当前已有服务器身份确认流程，未启动第二个连接")
            return
        }
        guard let port = UInt16(exactly: session.server.port), port > 0 else {
            session.terminalStatus = "连接失败"
            session.isConnected = false
            session.appendTerminal("[checked] 连接参数无效")
            return
        }
        let jumpHostInput: CheckedJumpHostInput?
        if let jumpHost = session.server.jumpHost {
            guard session.server.hasDistinctCredentialIDs,
                  jumpHost.isValid,
                  let jumpPort = UInt16(exactly: jumpHost.port) else {
                session.terminalStatus = "跳板机配置无效"
                session.isConnected = false
                session.appendTerminal("[checked] 跳板机主机、端口或用户名无效，未尝试直连")
                return
            }
            jumpHostInput = CheckedJumpHostInput(
                host: jumpHost.host,
                port: jumpPort,
                username: jumpHost.username,
                credentialReference: CredentialAccessReference(
                    id: jumpHost.credentialID,
                    allowPasswordFallback: jumpHost.allowPasswordFallback
                )
            )
        } else {
            jumpHostInput = nil
        }

        if session.baseSessionID != nil || session.terminalChannelID != nil ||
            !session.terminalChannelIDs.isEmpty || session.verifiedSessionLease != nil ||
            session.sftpManager.isConnected || session.dockerService.isConnected {
            session.appendTerminal("[checked] 正在重建已验证连接，先清理旧通道")
            await disconnect(session: session)
        }

        session.terminalStatus = "正在验证服务器身份..."
        session.isConnected = false
        session.appendTerminal("[checked] 正在建立已验证 SSH 连接")

        let orchestrator = CheckedTerminalConnectionOrchestrator(
            workspaceID: session.id,
            client: checkedClient
        )
        let route = CheckedHostKeyPresentationRoute(
            workspaceID: session.id,
            orchestrator: orchestrator
        )
        checkedHostKeyRoute = route

        let outcome = await orchestrator.begin(
            input: CheckedConnectInput(
                host: session.server.host,
                port: port,
                username: session.server.username,
                credentialReference: CredentialAccessReference(
                    id: session.server.credentialID,
                    allowPasswordFallback: session.server.allowPasswordFallback
                ),
                jumpHost: jumpHostInput
            )
        )
        applyCheckedOutcome(outcome, route: route)
    }

    func trustCheckedHostKey() async {
        guard let route = checkedHostKeyRoute else { return }
        applyCheckedOutcome(await route.orchestrator.trustCurrentChallenge(), route: route)
    }

    func retryCheckedHostKeySave() async {
        guard let route = checkedHostKeyRoute else { return }
        applyCheckedOutcome(await route.orchestrator.retrySave(), route: route)
    }

    func cancelCheckedHostKeyFlow() {
        guard let route = checkedHostKeyRoute else { return }
        applyCheckedOutcome(route.orchestrator.cancel(), route: route)
    }

    func closeCheckedHostKeyPresentation() {
        checkedHostKeyRoute?.orchestrator.close()
        checkedHostKeyRoute = nil
    }

    private func applyCheckedOutcome(
        _ outcome: CheckedTerminalConnectionOutcome,
        route: CheckedHostKeyPresentationRoute
    ) {
        guard checkedHostKeyRoute === route,
              let session = tabs.first(where: { $0.id == route.workspaceID }) else {
            return
        }

        switch outcome {
        case .pending:
            break
        case .awaitingUserDecision:
            session.terminalStatus = "等待服务器身份确认"
        case let .connected(lease):
            installCheckedLease(lease, on: session, terminalConnected: true)
            checkedHostKeyRoute = nil
        case let .terminalOpenFailed(lease, _):
            installCheckedLease(lease, on: session, terminalConnected: false)
            let recovery = OperationRecoveryMapper.connection(outcome)
            session.terminalStatus = recovery?.title ?? "终端未能打开"
            session.appendTerminal("[checked] \(recovery?.message ?? "终端未能打开")")
            checkedHostKeyRoute = nil
        case .blocked:
            let recovery = OperationRecoveryMapper.connection(outcome)
            session.terminalStatus = recovery?.title ?? "服务器身份已阻断"
            session.isConnected = false
            session.appendTerminal("[checked] \(recovery?.message ?? "服务器身份校验已阻断连接")")
        case let .failed(failure):
            let recovery = OperationRecoveryMapper.connection(failure)
            session.terminalStatus = recovery.title
            session.isConnected = false
            session.appendTerminal("[checked] \(recovery.message)")
        case .cancelled:
            let recovery = OperationRecoveryMapper.connection(outcome)
            session.terminalStatus = recovery?.title ?? "操作已取消"
            session.isConnected = false
            session.appendTerminal("[checked] \(recovery?.message ?? "操作已取消")")
            checkedHostKeyRoute = nil
        }
    }

    private func installCheckedLease(
        _ lease: VerifiedWorkspaceSession,
        on session: WorkspaceSession,
        terminalConnected: Bool
    ) {
        if let oldBase = session.baseSessionID, oldBase != lease.baseSessionID.ffiValue {
            sessionByBaseID.removeValue(forKey: oldBase)
        }
        session.verifiedSessionLease = lease
        session.baseSessionID = lease.baseSessionID.ffiValue
        sessionByBaseID[lease.baseSessionID.ffiValue] = session.id
        session.terminalChannelID = lease.terminalChannelID?.ffiValue
        session.terminalChannelIDs = lease.terminalChannelID.map { [$0.ffiValue] } ?? []
        session.activeTerminalPaneIndex = 0
        session.terminalSplitCount = 0
        session.isConnected = terminalConnected
        if terminalConnected {
            session.terminalStatus = "终端在线（已验证）"
            if let terminalChannelID = lease.terminalChannelID?.ffiValue {
                terminalService.beginFirstFrameMeasurement(channelID: terminalChannelID)
            }
            session.appendTerminal("[ok] 已验证 SSH 与终端通道建立成功")
            session.appendTerminal("[checked] 正在从已验证会话启动 SFTP、监控与 Docker；Batch 仍禁用")
            Task { [weak self, weak session] in
                guard let self, let session else { return }
                await self.startCheckedCompanionServices(for: session)
            }
        }
    }

    private func startCheckedCompanionServices(for session: WorkspaceSession) async {
        guard let baseSessionID = session.verifiedSessionLease?.baseSessionID,
              ownsCheckedCompanionServices(for: session, baseSessionID: baseSessionID) else {
            return
        }
        await openSFTPIfNeeded(for: session)
        guard ownsCheckedCompanionServices(for: session, baseSessionID: baseSessionID) else { return }
        await startMonitorIfNeeded(for: session)
        guard ownsCheckedCompanionServices(for: session, baseSessionID: baseSessionID) else { return }
        await startDockerIfNeeded(for: session)
    }

    /// A companion start is deliberately sequenced after terminal setup. Each
    /// await boundary revalidates the exact workspace object and verified base
    /// session so a late SFTP/Monitor/Docker completion cannot revive work for
    /// a closed tab or a newly connected generation of that tab.
    private func ownsCheckedCompanionServices(
        for session: WorkspaceSession,
        baseSessionID: BaseSessionID
    ) -> Bool {
        tabs.first(where: { $0.id == session.id }) === session &&
            session.server.transport == .ssh &&
            session.isConnected &&
            session.verifiedSessionLease?.baseSessionID == baseSessionID
    }

    private func rejectDisabledTelnet(session: WorkspaceSession) {
        session.terminalStatus = "Telnet 已禁用"
        session.isConnected = false
        session.appendTerminal("[security] Telnet 默认关闭，请先在设置中了解明文传输风险并手动启用")
    }

    private func requestTelnetRiskConfirmation(
        session: WorkspaceSession,
        target: TelnetTargetIdentity
    ) {
        guard telnetRiskRoute == nil else {
            session.terminalStatus = "等待其他 Telnet 确认完成"
            session.isConnected = false
            return
        }
        session.terminalStatus = "等待 Telnet 风险确认"
        session.isConnected = false
        session.appendTerminal("[security] Telnet 将以明文传输登录信息和终端内容，连接前需要确认")
        telnetRiskRoute = TelnetRiskPresentationRoute(
            workspaceID: session.id,
            target: target,
            displayName: session.server.name
        )
    }

    func confirmTelnetRiskAndConnect() async {
        guard let route = telnetRiskRoute,
              let session = tabs.first(where: { $0.id == route.workspaceID }),
              session.server.transport == .telnet,
              telnetAccessPolicy.isEnabled else {
            cancelTelnetRiskConfirmation()
            return
        }
        let currentTarget = TelnetTargetIdentity(
            serverID: session.server.id,
            host: session.server.host,
            port: session.server.port
        )
        guard currentTarget == route.target else {
            cancelTelnetRiskConfirmation()
            return
        }
        telnetAccessPolicy.confirm(route.target)
        telnetRiskRoute = nil
        await connectTelnet(session: session)
    }

    func cancelTelnetRiskConfirmation() {
        guard let route = telnetRiskRoute else { return }
        telnetRiskRoute = nil
        guard let session = tabs.first(where: { $0.id == route.workspaceID }) else { return }
        session.terminalStatus = "已取消 Telnet 连接"
        session.isConnected = false
        session.appendTerminal("[security] 用户未确认明文 Telnet 风险，未发起连接")
    }

    func disableTelnetAndDisconnect() async {
        telnetAccessPolicy.setEnabled(false)
        cancelTelnetRiskConfirmation()
        for session in tabs where session.server.transport == .telnet {
            await disconnect(session: session)
            session.terminalStatus = "Telnet 已禁用"
            session.appendTerminal("[security] Telnet 已关闭，现有明文会话已断开")
        }
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
        let virtualChannelID = terminalService.createVirtualChannel { [weak self, weak client] bytes in
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

    /// Non-blocking route for live keyboard input. The session and channel are
    /// resolved before queueing, so a later tab change cannot redirect bytes.
    func enqueueTerminalInput(session: WorkspaceSession, bytes: [UInt8], channelID: UInt64? = nil) {
        guard let targetChannelID = resolveChannelID(session: session, preferred: channelID) else { return }
        let submitted = session.captureTypedBytes(bytes)
        terminalService.enqueueInput(channelID: targetChannelID, bytes: bytes)
        if !submitted.isEmpty {
            Task { await syncSFTPPathIfNeeded(session: session, submittedCommands: submitted) }
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
        if let verifiedLease = session.verifiedSessionLease {
            let desired = max(1, min(4, session.terminalSplitCount + 1))
            while session.terminalChannelIDs.count < desired {
                let requestID = HostKeyRequestID()
                do {
                    let response = try await checkedClient.openTerminalChecked(
                        requestID: requestID,
                        baseSessionID: verifiedLease.baseSessionID,
                        cols: 120,
                        rows: 36
                    )
                    guard response.requestID == requestID,
                          response.value.baseSessionID == verifiedLease.baseSessionID,
                          session.isConnected,
                          session.verifiedSessionLease?.baseSessionID == verifiedLease.baseSessionID else {
                        await terminalService.unbindAndClose(
                            channelID: response.value.terminalChannelID.ffiValue
                        )
                        session.terminalSplitCount = max(0, session.terminalChannelIDs.count - 1)
                        return
                    }
                    session.terminalChannelIDs.append(response.value.terminalChannelID.ffiValue)
                } catch {
                    session.appendTerminal("[checked] 新分屏终端通道建立失败")
                    break
                }
            }
            while session.terminalChannelIDs.count > desired {
                if let removed = session.terminalChannelIDs.popLast() {
                    await terminalService.unbindAndClose(channelID: removed)
                }
            }
            session.terminalSplitCount = max(0, session.terminalChannelIDs.count - 1)
            session.activeTerminalPaneIndex = min(
                session.activeTerminalPaneIndex,
                max(0, session.terminalChannelIDs.count - 1)
            )
            session.terminalChannelID = session.terminalChannelIDs.first
            return
        }
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        guard checkedConnectionDispatcher.policy.allowsLegacyNetwork else {
            session.terminalSplitCount = 0
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
        #else
        session.terminalSplitCount = 0
        session.appendTerminal("[checked] 安全分屏通道迁移尚未启用")
        #endif
    }

    /// Closes one explicitly chosen auxiliary pane. Pane zero is the primary
    /// terminal channel and deliberately remains stable for the whole session.
    func removeTerminalSplit(session: WorkspaceSession, paneIndex: Int) async {
        guard session.server.transport != .telnet,
              paneIndex > 0,
              paneIndex < session.terminalChannelIDs.count else {
            return
        }

        let removedChannelID = session.terminalChannelIDs.remove(at: paneIndex)
        await terminalService.unbindAndClose(channelID: removedChannelID)

        if session.activeTerminalPaneIndex == paneIndex {
            session.activeTerminalPaneIndex = max(0, paneIndex - 1)
        } else if session.activeTerminalPaneIndex > paneIndex {
            session.activeTerminalPaneIndex -= 1
        }

        session.terminalSplitCount = max(0, session.terminalChannelIDs.count - 1)
        session.activeTerminalPaneIndex = min(
            session.activeTerminalPaneIndex,
            max(0, session.terminalChannelIDs.count - 1)
        )
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
            guard let nextPath = ShellPathResolver.resolve(
                command: command,
                currentPath: session.sftpManager.currentPath,
                username: session.server.username
            ) else {
                continue
            }
            if await session.sftpManager.goToPath(nextPath, reportErrors: false) {
                continue
            }
            for fallback in ShellPathResolver.fallbackPaths(for: nextPath, username: session.server.username) {
                if await session.sftpManager.goToPath(fallback, reportErrors: false) {
                    break
                }
            }
        }
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

    func disconnect(session: WorkspaceSession) async {
        if checkedHostKeyRoute?.workspaceID == session.id {
            _ = checkedHostKeyRoute?.orchestrator.cancel()
            checkedHostKeyRoute = nil
        }
        if telnetRiskRoute?.workspaceID == session.id {
            telnetRiskRoute = nil
        }
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
        await workspaceToolCoordinator.disconnectCompanionTools(for: session)
        if let baseID = session.baseSessionID {
            await terminalService.closeSSHSession(baseSessionID: baseID)
            sessionByBaseID.removeValue(forKey: baseID)
        }
        session.terminalChannelIDs = []
        session.terminalChannelID = nil
        session.baseSessionID = nil
        session.verifiedSessionLease = nil
        session.activeMonitorPanelID = nil
        session.isConnected = false
        session.terminalStatus = "未连接"
    }
}
