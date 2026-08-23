import Foundation
import Network
import os

private enum AppleTCPLatencyProbe {
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let continuation: CheckedContinuation<Double?, Never>

        init(_ continuation: CheckedContinuation<Double?, Never>) {
            self.continuation = continuation
        }

        func finish(_ value: Double?) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            lock.unlock()
            continuation.resume(returning: value)
        }
    }

    /// Measures the client-to-server TCP handshake for the actual SSH endpoint.
    /// It sends no protocol bytes and never touches credentials.
    static func measure(host: String, port: Int, timeout: TimeInterval = 2) async -> Double? {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty,
              (1...65_535).contains(port),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let completion = Completion(continuation)
            let queue = DispatchQueue(label: "com.orbitterm.tcp-latency", qos: .utility)
            let connection = NWConnection(host: NWEndpoint.Host(normalizedHost), port: nwPort, using: .tcp)
            let startedAt = DispatchTime.now().uptimeNanoseconds

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
                    connection.cancel()
                    completion.finish(Double(elapsed) / 1_000_000)
                case .failed, .cancelled:
                    completion.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + max(0.2, timeout)) {
                connection.cancel()
                completion.finish(nil)
            }
        }
    }
}

struct MonitorTargetConfig: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var credentialID: UUID

    init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String, credentialID: UUID? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.credentialID = credentialID ?? id
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case port
        case username
        case credentialID
        case password // 旧字段，仅用于迁移读取
    }

    var legacyPassword: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decode(String.self, forKey: .username)
        credentialID = try c.decodeIfPresent(UUID.self, forKey: .credentialID) ?? id
        legacyPassword = try c.decodeIfPresent(String.self, forKey: .password)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(credentialID, forKey: .credentialID)
    }
}

struct MonitorPoint: Identifiable, Hashable {
    let id = UUID()
    let time: Date
    let cpuUsage: Double
    let memUsedPercent: Double
    let diskUsedPercent: Double
    let pingLatencyMs: Double?
    let rxRateKBps: Double
    let txRateKBps: Double
    let systemInfo: MonitorSystemInfo

    init(
        time: Date,
        cpuUsage: Double,
        memUsedPercent: Double,
        diskUsedPercent: Double,
        pingLatencyMs: Double?,
        rxRateKBps: Double,
        txRateKBps: Double,
        systemInfo: MonitorSystemInfo = .unavailable
    ) {
        self.time = time
        self.cpuUsage = cpuUsage
        self.memUsedPercent = memUsedPercent
        self.diskUsedPercent = diskUsedPercent
        self.pingLatencyMs = pingLatencyMs
        self.rxRateKBps = rxRateKBps
        self.txRateKBps = txRateKBps
        self.systemInfo = systemInfo
    }

    var cpuZone: String {
        if cpuUsage >= 90 { return "alert" }
        if cpuUsage >= 75 { return "warning" }
        return "normal"
    }
}

struct MonitorPanelState: Identifiable {
    let id: UUID
    var target: MonitorTargetConfig
    var isRunning: Bool
    var status: String
    var points: [MonitorPoint]
}

@MainActor
final class MonitorService: ObservableObject {
    @Published private(set) var panels: [MonitorPanelState] = []
    @Published private(set) var checkedErrors: [UUID: CheckedMonitorServiceError] = [:]

    func recoveryPresentation(for targetID: UUID?) -> OperationRecoveryPresentation? {
        guard let targetID, let error = checkedErrors[targetID] else { return nil }
        return OperationRecoveryMapper.monitor(error)
    }

    private let logger = Logger(subsystem: "com.orbitterm.app", category: "monitor")
    private let connectionMode: ConnectionSecurityPolicy
    private let checkedSnapshotService: (any CheckedMonitorSnapshotFetching)?
    private var buffers: [UUID: BoundedCircularBuffer<MonitorPoint>] = [:]
    private var sessions: [UUID: UInt64] = [:]
    private var checkedBindings: [UUID: CheckedMonitorBinding] = [:]
    private var checkedEndpoints: [UUID: (host: String, port: Int)] = [:]
    private var checkedPollers: [UUID: CheckedMonitorPollingLoop] = [:]
    private var checkedDeliveryOwners: [UUID: OperationOwner] = [:]
    private var consecutiveFailures: [UUID: Int] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var pollTasks: [UUID: Task<Void, Never>] = [:]
    private var allowPasswordFallbackByTarget: [UUID: Bool] = [:]

    private let intervalKey = "orbitterm.monitor.realtime.interval"
    private let vault = CredentialVault.shared
    private let targetStore = MonitorTargetStore()

    init(
        connectionMode: ConnectionSecurityPolicy = .applicationDefault,
        checkedSnapshotService: (any CheckedMonitorSnapshotFetching)? = nil
    ) {
        self.connectionMode = connectionMode
        self.checkedSnapshotService = checkedSnapshotService
        loadTargets()
    }

    deinit {
        for (_, task) in pollTasks {
            task.cancel()
        }
        for (_, task) in reconnectTasks {
            task.cancel()
        }
    }

    func addTarget(name: String, host: String, port: Int = 22, username: String, credentials: ServerCredentials) {
        guard connectionMode.allowsLegacyNetwork else { return }
        let target = MonitorTargetConfig(name: name, host: host, port: port, username: username)
        try? vault.save(credentials, for: target.credentialID)
        panels.append(MonitorPanelState(id: target.id, target: target, isRunning: false, status: "未连接", points: []))
        buffers[target.id] = BoundedCircularBuffer(capacity: OperationResourceBudget.monitorPointsPerPanel)
        persistTargets()
    }

    // 为工作台模式准备：若目标已存在则复用，否则创建并返回目标 ID。
    func ensureTarget(name: String, host: String, port: Int = 22, username: String, credentials: ServerCredentials) -> UUID {
        guard connectionMode.allowsLegacyNetwork else {
            return ensureCheckedPanel(workspaceID: UUID(), name: name)
        }
        if let existing = panels.first(where: {
            $0.target.host == host && $0.target.port == port && $0.target.username == username
        }) {
            try? vault.save(credentials, for: existing.target.credentialID)
            return existing.id
        }

        let target = MonitorTargetConfig(name: name, host: host, port: port, username: username)
        try? vault.save(credentials, for: target.credentialID)
        panels.append(MonitorPanelState(id: target.id, target: target, isRunning: false, status: "未连接", points: []))
        buffers[target.id] = BoundedCircularBuffer(capacity: OperationResourceBudget.monitorPointsPerPanel)
        persistTargets()
        return target.id
    }

    func startMonitoring(
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        credentials: ServerCredentials,
        allowPasswordFallback: Bool,
        baseSessionID: UInt64? = nil
    ) async -> UUID {
        guard connectionMode.allowsLegacyNetwork else {
            return ensureCheckedPanel(workspaceID: UUID(), name: name)
        }
        let id = ensureTarget(name: name, host: host, port: port, username: username, credentials: credentials)
        if let baseSessionID {
            await connect(id, baseSessionID: baseSessionID, allowPasswordFallback: allowPasswordFallback)
        } else {
            await connect(id, allowPasswordFallback: allowPasswordFallback, credentialsOverride: credentials)
        }
        return id
    }

    func panel(id: UUID?) -> MonitorPanelState? {
        guard let id else { return nil }
        return panels.first(where: { $0.id == id })
    }

    func removeTarget(_ targetID: UUID) {
        let isChecked = checkedBindings[targetID] != nil
        if !isChecked, let target = panels.first(where: { $0.id == targetID })?.target {
            try? vault.delete(for: target.credentialID)
        }
        reconnectTasks[targetID]?.cancel()
        reconnectTasks.removeValue(forKey: targetID)
        stopPolling(targetID)
        if isChecked {
            invalidateCheckedDelivery(for: targetID)
            let poller = checkedPollers[targetID]
            Task { await poller?.stop() }
        } else {
            Task { await disconnect(targetID) }
        }
        panels.removeAll { $0.id == targetID }
        buffers.removeValue(forKey: targetID)
        sessions.removeValue(forKey: targetID)
        checkedBindings.removeValue(forKey: targetID)
        checkedPollers.removeValue(forKey: targetID)
        checkedDeliveryOwners.removeValue(forKey: targetID)
        checkedErrors.removeValue(forKey: targetID)
        consecutiveFailures.removeValue(forKey: targetID)
        allowPasswordFallbackByTarget.removeValue(forKey: targetID)
        persistTargets()
    }

    func connect(
        _ targetID: UUID,
        allowPasswordFallback: Bool = true,
        credentialsOverride: ServerCredentials? = nil
    ) async {
        guard connectionMode.allowsLegacyNetwork else {
            rejectLegacyMonitor(targetID)
            return
        }
        guard let index = panels.firstIndex(where: { $0.id == targetID }) else { return }
        let target = panels[index].target
        let credentials = credentialsOverride ?? (try? vault.read(for: target.credentialID) ?? ServerCredentials())
        guard let credentials, !credentials.isEmpty else {
            panels[index].status = "连接失败: 未找到监控凭据"
            panels[index].isRunning = false
            return
        }

        do {
            let payload = try await callRustWithTimeout(seconds: 12, label: "connect") {
                RustFFI.connectSFTP(
                    host: target.host,
                    port: target.port,
                    username: target.username,
                    password: credentials.password,
                    privateKeyContent: credentials.privateKeyContent,
                    privateKeyPassphrase: credentials.privateKeyPassphrase,
                    allowPasswordFallback: allowPasswordFallback
                )
            }

            guard let sessionID = UInt64(payload) else {
                throw SFTPError.invalidResponse
            }

            sessions[targetID] = sessionID
            consecutiveFailures[targetID] = 0
            allowPasswordFallbackByTarget[targetID] = allowPasswordFallback
            panels[index].isRunning = true
            panels[index].status = "监控中"
            startPolling(targetID)
            logger.debug("[MON] connected target=\(target.name, privacy: .private(mask: .hash)) sid=\(sessionID, privacy: .private(mask: .hash))")
        } catch {
            panels[index].status = "连接失败: \(error.localizedDescription)"
            panels[index].isRunning = false
        }
    }

    func connect(
        _ targetID: UUID,
        baseSessionID: UInt64,
        allowPasswordFallback: Bool = true
    ) async {
        guard connectionMode.allowsLegacyNetwork else {
            rejectLegacyMonitor(targetID)
            return
        }
        guard let index = panels.firstIndex(where: { $0.id == targetID }) else { return }

        do {
            let payload = try await callRustWithTimeout(seconds: 8, label: "reuse_connect") {
                RustFFI.requestChannel(baseSessionID: baseSessionID, type: "sftp")
            }

            guard let sessionID = UInt64(payload) else {
                throw SFTPError.invalidResponse
            }

            sessions[targetID] = sessionID
            consecutiveFailures[targetID] = 0
            allowPasswordFallbackByTarget[targetID] = allowPasswordFallback
            panels[index].isRunning = true
            panels[index].status = "监控中"
            startPolling(targetID)
            logger.debug("[MON] reused base session target=\(self.panels[index].target.name, privacy: .private(mask: .hash)) sid=\(sessionID, privacy: .private(mask: .hash))")
        } catch {
            panels[index].status = "连接失败: \(error.localizedDescription)"
            panels[index].isRunning = false
        }
    }

    func disconnect(_ targetID: UUID) async {
        if checkedBindings[targetID] != nil {
            invalidateCheckedDelivery(for: targetID)
            await checkedPollers[targetID]?.stop()
            checkedPollers.removeValue(forKey: targetID)
            checkedBindings.removeValue(forKey: targetID)
            checkedEndpoints.removeValue(forKey: targetID)
            checkedDeliveryOwners.removeValue(forKey: targetID)
            checkedErrors.removeValue(forKey: targetID)
            if let index = panels.firstIndex(where: { $0.id == targetID }) {
                panels[index].isRunning = false
                panels[index].status = "已停止"
            }
            return
        }
        reconnectTasks[targetID]?.cancel()
        reconnectTasks.removeValue(forKey: targetID)
        stopPolling(targetID)
        guard let sid = sessions[targetID] else { return }
        _ = try? await callRustWithTimeout(seconds: 8, label: "disconnect") {
            orbit_sftp_disconnect(sid)
        }
        sessions.removeValue(forKey: targetID)
        consecutiveFailures[targetID] = 0
        allowPasswordFallbackByTarget.removeValue(forKey: targetID)
        if let index = panels.firstIndex(where: { $0.id == targetID }) {
            panels[index].isRunning = false
            panels[index].status = "已断开"
        }
    }

    private func startPolling(_ targetID: UUID) {
        guard pollTasks[targetID] == nil else { return }
        pollTasks[targetID] = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard MonitorRefreshPreference.isEnabled() else {
                    if let index = self.panels.firstIndex(where: { $0.id == targetID }) {
                        self.panels[index].status = "监控自动刷新已暂停"
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                let start = Date()
                await self.pollTargetOnce(targetID)

                // 背压策略：上一轮完成（成功或超时）后，再等待剩余时间补齐配置周期。
                let configuredInterval = MonitorPollingPolicy.configuredInterval(key: self.intervalKey)
                let delay = MonitorPollingPolicy.delayAfterRequest(startedAt: start, interval: configuredInterval)
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }

                guard self.panels.contains(where: { $0.id == targetID && $0.isRunning }) else {
                    break
                }
            }
            self.pollTasks.removeValue(forKey: targetID)
        }
    }

    private func stopPolling(_ targetID: UUID) {
        pollTasks[targetID]?.cancel()
        pollTasks.removeValue(forKey: targetID)
    }

    private func pollTargetOnce(_ targetID: UUID) async {
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        guard let sid = sessions[targetID],
              let panelIndex = panels.firstIndex(where: { $0.id == targetID }) else {
            return
        }

        do {
            let payload = try await callRustWithTimeout(seconds: 8, label: "fetch_stats") {
                orbit_fetch_system_stats(sid)
            }

            let stats = try JSONDecoder().decode(RustSystemStatsPayload.self, from: Data(payload.utf8))
            let tcpLatency = await AppleTCPLatencyProbe.measure(
                host: panels[panelIndex].target.host,
                port: panels[panelIndex].target.port
            )
            let recentLatency = buffers[targetID]?.elementsInOrder.map(\.pingLatencyMs) ?? []
            let point = stats.monitorPoint.replacingLatency(
                with: TCPLatencySamplePolicy.stabilized(current: tcpLatency, recent: recentLatency)
            )

            var buffer = buffers[targetID] ?? BoundedCircularBuffer(capacity: OperationResourceBudget.monitorPointsPerPanel)
            buffer.append(point)
            buffers[targetID] = buffer

            consecutiveFailures[targetID] = 0
            panels[panelIndex].points = buffer.elementsInOrder
            panels[panelIndex].status = "实时监控中"
        } catch {
            let count = (consecutiveFailures[targetID] ?? 0) + 1
            consecutiveFailures[targetID] = count

            panels[panelIndex].status = "采集失败: \(error.localizedDescription)"
            if case SFTPError.timeout = error {
                panels[panelIndex].status = "采集超时，正在重试..."
            }

            if MonitorPollingPolicy.shouldAutoHeal(error: error, failureCount: count) {
                panels[panelIndex].status = "采集中断，后台静默重连中..."
                scheduleSilentReconnect(targetID)
            }
        }
        #else
        stopPolling(targetID)
        #endif
    }

    private func scheduleSilentReconnect(_ targetID: UUID) {
        guard connectionMode.allowsLegacyNetwork, checkedBindings[targetID] == nil else { return }
        guard reconnectTasks[targetID] == nil else { return }

        reconnectTasks[targetID] = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.reconnectTasks[targetID] = nil }

            for sec in MonitorPollingPolicy.reconnectBackoffSeconds {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: sec * 1_000_000_000)
                let ok = await reconnectMonitorSession(targetID)
                if ok { return }
            }

            if let idx = self.panels.firstIndex(where: { $0.id == targetID }) {
                self.panels[idx].status = "监控暂不可用，等待网络恢复"
            }
        }
    }

    private func reconnectMonitorSession(_ targetID: UUID) async -> Bool {
        guard connectionMode.allowsLegacyNetwork, checkedBindings[targetID] == nil else { return false }
        guard let index = panels.firstIndex(where: { $0.id == targetID }) else { return false }
        guard panels[index].isRunning else { return true }
        let target = panels[index].target

        guard let credentials = try? vault.read(for: target.credentialID) ?? ServerCredentials(),
              !credentials.isEmpty else {
            panels[index].status = "重连失败: 凭据缺失"
            return false
        }

        let allowFallback = allowPasswordFallbackByTarget[targetID] ?? true

        do {
            if let oldSID = sessions[targetID] {
                _ = try? await callRustWithTimeout(seconds: 5, label: "reconnect_disconnect") {
                    orbit_sftp_disconnect(oldSID)
                }
            }

            let payload = try await callRustWithTimeout(seconds: 12, label: "reconnect_connect") {
                RustFFI.connectSFTP(
                    host: target.host,
                    port: target.port,
                    username: target.username,
                    password: credentials.password,
                    privateKeyContent: credentials.privateKeyContent,
                    privateKeyPassphrase: credentials.privateKeyPassphrase,
                    allowPasswordFallback: allowFallback
                )
            }

            guard let newSID = UInt64(payload) else {
                throw SFTPError.invalidResponse
            }

            sessions[targetID] = newSID
            consecutiveFailures[targetID] = 0
            panels[index].status = "监控已恢复"
            startPolling(targetID)
            logger.debug("[MON] healed target=\(target.name, privacy: .private(mask: .hash)) sid=\(newSID, privacy: .private(mask: .hash))")
            return true
        } catch {
            panels[index].status = "重连中..."
            return false
        }
    }

    private func loadTargets() {
        let result = targetStore.load()
        let targets = result.targets

        panels = targets.map {
            let status = $0.host.isEmpty ? "请先配置服务器" : "未连接"
            return MonitorPanelState(id: $0.id, target: $0, isRunning: false, status: status, points: [])
        }
        for target in targets {
            buffers[target.id] = BoundedCircularBuffer(capacity: OperationResourceBudget.monitorPointsPerPanel)
        }

        if result.needsRewrite {
            targetStore.clear()
            persistTargets()
        }
    }

    private func persistTargets() {
        let targets = panels
            .filter { checkedBindings[$0.id] == nil }
            .map(\.target)
        targetStore.save(targets)
    }

    func startCheckedMonitoring(
        workspaceID: UUID,
        baseSessionID: BaseSessionID,
        name: String,
        host: String,
        port: Int
    ) async -> Result<UUID, CheckedMonitorServiceError> {
        guard connectionMode.requiresCheckedNetwork else {
            return .failure(.legacyMonitorDisabledInCheckedMode)
        }
        guard let checkedSnapshotService else {
            return .failure(.internalInvariant)
        }

        let targetID = ensureCheckedPanel(
            workspaceID: workspaceID,
            name: name,
            host: host,
            port: port
        )
        let binding = CheckedMonitorBinding(
            workspaceID: workspaceID,
            baseSessionID: baseSessionID
        )
        let poller = CheckedMonitorPollingLoop(
            binding: binding,
            fetcher: checkedSnapshotService,
            intervalNanoseconds: checkedPollingIntervalNanoseconds,
            isEnabled: checkedPollingEnabled
        )
        checkedBindings[targetID] = binding
        checkedEndpoints[targetID] = (host, port)
        checkedErrors.removeValue(forKey: targetID)
        await startCheckedPolling(targetID: targetID, binding: binding, poller: poller)
        if !MonitorRefreshPreference.isEnabled() {
            await suspendMonitoring(targetID)
        }
        return .success(targetID)
    }

    /// Applies the user's global monitoring preference to every live panel.
    /// Existing verified SSH sessions are retained; only snapshot polling is
    /// suspended or resumed, so changing this setting cannot create a second
    /// connection or disturb terminal/SFTP work.
    func applyAutoRefreshPreference(_ enabled: Bool) async {
        let targetIDs = panels.map(\.id)
        for targetID in targetIDs {
            if enabled {
                await resumeMonitoring(targetID)
            } else {
                await suspendMonitoring(targetID)
            }
        }
    }

    /// Stops polling work without closing the verified session. It is safe to
    /// call for an inactive tab or application and rejects any delayed result.
    func suspendMonitoring(_ targetID: UUID) async {
        invalidateCheckedDelivery(for: targetID)
        reconnectTasks[targetID]?.cancel()
        reconnectTasks.removeValue(forKey: targetID)
        stopPolling(targetID)

        let poller = checkedPollers[targetID]
        checkedPollers.removeValue(forKey: targetID)
        await poller?.stop()

        if let index = panels.firstIndex(where: { $0.id == targetID }) {
            panels[index].isRunning = false
            panels[index].status = checkedBindings[targetID] == nil
                ? "监控已暂停"
                : "安全监控已暂停"
        }
    }

    /// Reuses the existing checked binding, so resuming monitoring never
    /// creates another SSH or SFTP channel.
    func resumeMonitoring(_ targetID: UUID) async {
        if let binding = checkedBindings[targetID] {
            guard let checkedSnapshotService else { return }
            let poller = CheckedMonitorPollingLoop(
                binding: binding,
                fetcher: checkedSnapshotService,
                intervalNanoseconds: checkedPollingIntervalNanoseconds,
                isEnabled: checkedPollingEnabled
            )
            await startCheckedPolling(targetID: targetID, binding: binding, poller: poller)
            return
        }

        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        guard sessions[targetID] != nil else { return }
        if let index = panels.firstIndex(where: { $0.id == targetID }) {
            panels[index].isRunning = true
            panels[index].status = "监控恢复中"
        }
        startPolling(targetID)
        #endif
    }

    /// Restarts only the existing monitor polling loop so the next snapshot is
    /// fetched immediately. The checked binding is reused verbatim: this does
    /// not create a new SSH connection or an auxiliary SFTP channel.
    func refreshMonitoring(_ targetID: UUID) async {
        if let binding = checkedBindings[targetID] {
            guard let checkedSnapshotService else { return }
            if !MonitorRefreshPreference.isEnabled() {
                let lease = beginCheckedDelivery(for: targetID)
                let result: Result<MonitorSnapshotPayload, CheckedMonitorServiceError>
                do {
                    result = .success(try await checkedSnapshotService.snapshot(binding: binding))
                } catch let error as CheckedMonitorServiceError {
                    result = .failure(error)
                } catch {
                    result = .failure(.unknownCheckedFFIError)
                }
                await applyCheckedSnapshotResult(
                    result,
                    targetID: targetID,
                    binding: binding,
                    lease: lease
                )
                if let index = panels.firstIndex(where: { $0.id == targetID }) {
                    panels[index].isRunning = false
                    panels[index].status = "已手动刷新，自动刷新仍暂停"
                }
                return
            }
            let poller = CheckedMonitorPollingLoop(
                binding: binding,
                fetcher: checkedSnapshotService,
                intervalNanoseconds: checkedPollingIntervalNanoseconds,
                isEnabled: checkedPollingEnabled
            )
            await startCheckedPolling(targetID: targetID, binding: binding, poller: poller)
            return
        }

        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        await pollTargetOnce(targetID)
        #endif
    }

    func rejectCheckedStandalone(_ error: CheckedMonitorServiceError = .requiresVerifiedSession) {
        let targetID = ensureCheckedPanel(workspaceID: UUID(), name: "安全监控")
        checkedErrors[targetID] = error
        if let index = panels.firstIndex(where: { $0.id == targetID }) {
            panels[index].isRunning = false
            panels[index].status = error.userMessage
        }
    }

    func checkedBinding(for targetID: UUID) -> CheckedMonitorBinding? {
        checkedBindings[targetID]
    }

    private func ensureCheckedPanel(
        workspaceID: UUID,
        name: String,
        host: String = "",
        port: Int = 22
    ) -> UUID {
        if let index = panels.firstIndex(where: { $0.id == workspaceID }) {
            if !host.isEmpty {
                panels[index].target.host = host
                panels[index].target.port = port
                panels[index].target.name = name
            }
            return panels[index].id
        }
        let target = MonitorTargetConfig(
            id: workspaceID,
            name: name,
            host: host,
            port: port,
            username: "",
            credentialID: workspaceID
        )
        panels.append(
            MonitorPanelState(
                id: workspaceID,
                target: target,
                isRunning: false,
                status: "需要已验证会话",
                points: []
            )
        )
        buffers[workspaceID] = BoundedCircularBuffer(capacity: OperationResourceBudget.monitorPointsPerPanel)
        return workspaceID
    }

    private func rejectLegacyMonitor(_ targetID: UUID) {
        let error = CheckedMonitorServiceError.legacyMonitorDisabledInCheckedMode
        checkedErrors[targetID] = error
        if let index = panels.firstIndex(where: { $0.id == targetID }) {
            panels[index].isRunning = false
            panels[index].status = error.userMessage
        }
    }

    private func applyCheckedSnapshotResult(
        _ result: Result<MonitorSnapshotPayload, CheckedMonitorServiceError>,
        targetID: UUID,
        binding: CheckedMonitorBinding,
        lease: OperationLease
    ) async {
        guard acceptsCheckedDelivery(lease, for: targetID),
              checkedBindings[targetID] == binding,
              let panelIndex = panels.firstIndex(where: { $0.id == targetID }) else {
            return
        }

        switch result {
        case let .success(payload):
            let endpoint = checkedEndpoints[targetID]
            let tcpLatency: Double?
            if let endpoint {
                tcpLatency = await AppleTCPLatencyProbe.measure(host: endpoint.host, port: endpoint.port)
            } else {
                tcpLatency = nil
            }
            // The TCP handshake can outlive a tab switch or disconnect. Never
            // publish that delayed sample into a replacement workspace.
            guard acceptsCheckedDelivery(lease, for: targetID),
                  checkedBindings[targetID] == binding,
                  let currentPanelIndex = panels.firstIndex(where: { $0.id == targetID }) else {
                return
            }
            checkedErrors.removeValue(forKey: targetID)
            var buffer = buffers[targetID] ?? BoundedCircularBuffer(capacity: OperationResourceBudget.monitorPointsPerPanel)
            let stableLatency = TCPLatencySamplePolicy.stabilized(
                current: tcpLatency,
                recent: buffer.elementsInOrder.map(\.pingLatencyMs)
            )
            buffer.append(payload.stats.monitorPoint.replacingLatency(with: stableLatency))
            buffers[targetID] = buffer
            panels[currentPanelIndex].points = buffer.elementsInOrder
            panels[currentPanelIndex].isRunning = true
            panels[currentPanelIndex].status = tcpLatency == nil
                ? "安全监控中（SSH 端口 TCP 延迟不可用）"
                : "安全监控中"
        case let .failure(error):
            checkedErrors[targetID] = error
            if error.shouldContinuePolling {
                panels[panelIndex].isRunning = true
                panels[panelIndex].status = error.retryMessage
            } else {
                panels[panelIndex].isRunning = false
                panels[panelIndex].status = error.userMessage
                checkedPollers.removeValue(forKey: targetID)
            }
        }
    }

    private var checkedPollingIntervalNanoseconds: UInt64 {
        let seconds = MonitorPollingPolicy.configuredInterval(key: intervalKey)
        return UInt64(max(0.1, seconds) * 1_000_000_000)
    }

    private var checkedPollingEnabled: @Sendable () -> Bool {
        { MonitorRefreshPreference.isEnabled() }
    }

    private func startCheckedPolling(
        targetID: UUID,
        binding: CheckedMonitorBinding,
        poller: CheckedMonitorPollingLoop
    ) async {
        let priorPoller = checkedPollers[targetID]
        checkedPollers[targetID] = nil
        await priorPoller?.stop()

        let lease = beginCheckedDelivery(for: targetID)
        checkedBindings[targetID] = binding
        checkedPollers[targetID] = poller
        if let index = panels.firstIndex(where: { $0.id == targetID }) {
            panels[index].isRunning = true
            panels[index].status = "安全监控启动中"
        }

        await poller.start { [weak self] result in
            await self?.applyCheckedSnapshotResult(
                result,
                targetID: targetID,
                binding: binding,
                lease: lease
            )
        }
    }

    private func beginCheckedDelivery(for targetID: UUID) -> OperationLease {
        var owner = checkedDeliveryOwners[targetID] ?? OperationOwner()
        let lease = owner.begin(scope: .workspace(targetID))
        checkedDeliveryOwners[targetID] = owner
        return lease
    }

    private func invalidateCheckedDelivery(for targetID: UUID) {
        guard var owner = checkedDeliveryOwners[targetID] else { return }
        owner.invalidate()
        checkedDeliveryOwners[targetID] = owner
    }

    private func acceptsCheckedDelivery(_ lease: OperationLease, for targetID: UUID) -> Bool {
        checkedDeliveryOwners[targetID]?.owns(lease, scope: .workspace(targetID)) == true
    }

    private func callRustWithTimeout(
        seconds: TimeInterval,
        label: String,
        _ call: @escaping @Sendable () -> UnsafeMutablePointer<CChar>?
    ) async throws -> String {
        let payload = try await RustFFI.callWithTimeout(seconds: seconds, call)
        logger.debug("[MON] rust_call=\(label, privacy: .private(mask: .hash)) bytes=\(payload.utf8.count)")
        return payload
    }
}

extension MonitorService: WorkspaceMonitoring {}

private extension MonitorSnapshotStatsPayload {
    var monitorPoint: MonitorPoint {
        MonitorPoint(
            time: Date(timeIntervalSince1970: TimeInterval(sampledAtUnix)),
            cpuUsage: cpuUsagePercent,
            memUsedPercent: memUsedPercent,
            diskUsedPercent: diskUsedPercent,
            pingLatencyMs: pingLatencyMS,
            rxRateKBps: rxRateKBPS,
            txRateKBps: txRateKBPS,
            systemInfo: systemInfo
        )
    }
}

private extension MonitorPoint {
    func replacingLatency(with tcpLatencyMS: Double?) -> MonitorPoint {
        MonitorPoint(
            time: time,
            cpuUsage: cpuUsage,
            memUsedPercent: memUsedPercent,
            diskUsedPercent: diskUsedPercent,
            pingLatencyMs: tcpLatencyMS,
            rxRateKBps: rxRateKBps,
            txRateKBps: txRateKBps,
            systemInfo: systemInfo
        )
    }
}
