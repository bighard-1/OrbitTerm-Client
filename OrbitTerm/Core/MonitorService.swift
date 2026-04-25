import Foundation
import os

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

struct CircularBuffer<Element> {
    private var storage: [Element] = []
    private var cursor = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
            return
        }

        storage[cursor] = element
        cursor = (cursor + 1) % capacity
    }

    var elementsInOrder: [Element] {
        guard storage.count == capacity else { return storage }
        return Array(storage[cursor...]) + Array(storage[..<cursor])
    }
}

private struct RustSystemStatsPayload: Decodable {
    let sampledAtUnix: UInt64
    let cpuUsagePercent: Double
    let memAvailableMb: UInt64
    let memUsedPercent: Double
    let diskUsedPercent: Double
    let pingLatencyMs: Double?
    let rxRateKbps: Double
    let txRateKbps: Double

    enum CodingKeys: String, CodingKey {
        case sampledAtUnix = "sampled_at_unix"
        case cpuUsagePercent = "cpu_usage_percent"
        case memAvailableMb = "mem_available_mb"
        case memUsedPercent = "mem_used_percent"
        case diskUsedPercent = "disk_used_percent"
        case pingLatencyMs = "ping_latency_ms"
        case rxRateKbps = "rx_rate_kbps"
        case txRateKbps = "tx_rate_kbps"
    }
}

@MainActor
final class MonitorService: ObservableObject {
    @Published private(set) var panels: [MonitorPanelState] = []

    private let logger = Logger(subsystem: "com.orbitterm.app", category: "monitor")
    private var buffers: [UUID: CircularBuffer<MonitorPoint>] = [:]
    private var sessions: [UUID: UInt64] = [:]
    private var consecutiveFailures: [UUID: Int] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var allowPasswordFallbackByTarget: [UUID: Bool] = [:]
    private var loopTask: Task<Void, Never>?

    private let userDefaultsKey = "monitor.targets.v1"
    private let migrationFlagKey = "monitor.targets.credentials.migrated.v1"
    private let vault = CredentialVault.shared

    init() {
        loadTargets()
        startBackgroundLoop()
    }

    deinit {
        loopTask?.cancel()
    }

    func addTarget(name: String, host: String, port: Int = 22, username: String, credentials: ServerCredentials) {
        let target = MonitorTargetConfig(name: name, host: host, port: port, username: username)
        try? vault.save(credentials, for: target.credentialID)
        panels.append(MonitorPanelState(id: target.id, target: target, isRunning: false, status: "未连接", points: []))
        buffers[target.id] = CircularBuffer(capacity: 600)
        persistTargets()
    }

    // 为工作台模式准备：若目标已存在则复用，否则创建并返回目标 ID。
    func ensureTarget(name: String, host: String, port: Int = 22, username: String, credentials: ServerCredentials) -> UUID {
        if let existing = panels.first(where: {
            $0.target.host == host && $0.target.port == port && $0.target.username == username
        }) {
            try? vault.save(credentials, for: existing.target.credentialID)
            return existing.id
        }

        let target = MonitorTargetConfig(name: name, host: host, port: port, username: username)
        try? vault.save(credentials, for: target.credentialID)
        panels.append(MonitorPanelState(id: target.id, target: target, isRunning: false, status: "未连接", points: []))
        buffers[target.id] = CircularBuffer(capacity: 600)
        persistTargets()
        return target.id
    }

    func startMonitoring(
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        credentials: ServerCredentials,
        allowPasswordFallback: Bool
    ) async -> UUID {
        let id = ensureTarget(name: name, host: host, port: port, username: username, credentials: credentials)
        await connect(id, allowPasswordFallback: allowPasswordFallback, credentialsOverride: credentials)
        return id
    }

    func panel(id: UUID?) -> MonitorPanelState? {
        guard let id else { return nil }
        return panels.first(where: { $0.id == id })
    }

    func removeTarget(_ targetID: UUID) {
        if let target = panels.first(where: { $0.id == targetID })?.target {
            try? vault.delete(for: target.credentialID)
        }
        reconnectTasks[targetID]?.cancel()
        reconnectTasks.removeValue(forKey: targetID)
        Task { await disconnect(targetID) }
        panels.removeAll { $0.id == targetID }
        buffers.removeValue(forKey: targetID)
        sessions.removeValue(forKey: targetID)
        consecutiveFailures.removeValue(forKey: targetID)
        allowPasswordFallbackByTarget.removeValue(forKey: targetID)
        persistTargets()
    }

    func connect(
        _ targetID: UUID,
        allowPasswordFallback: Bool = true,
        credentialsOverride: ServerCredentials? = nil
    ) async {
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
                target.host.withCString { host in
                    target.username.withCString { user in
                        credentials.password.withCString { password in
                                credentials.privateKeyContent.withCString { k in
                                    credentials.privateKeyPassphrase.withCString { passphrase in
                                        orbit_sftp_connect(
                                            host,
                                            Int32(max(1, min(65535, target.port))),
                                            user,
                                            password,
                                            k,
                                            passphrase,
                                            allowPasswordFallback ? 1 : 0
                                        )
                                    }
                                }
                            }
                    }
                }
            }

            guard let sessionID = UInt64(payload) else {
                throw SFTPError.invalidResponse
            }

            sessions[targetID] = sessionID
            consecutiveFailures[targetID] = 0
            allowPasswordFallbackByTarget[targetID] = allowPasswordFallback
            panels[index].isRunning = true
            panels[index].status = "监控中"
            logger.debug("[MON] connected target=\(target.name, privacy: .public) sid=\(sessionID)")
        } catch {
            panels[index].status = "连接失败: \(error.localizedDescription)"
            panels[index].isRunning = false
        }
    }

    func disconnect(_ targetID: UUID) async {
        reconnectTasks[targetID]?.cancel()
        reconnectTasks.removeValue(forKey: targetID)
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

    private func startBackgroundLoop() {
        loopTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollAllTargets()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func pollAllTargets() async {
        for panel in panels where panel.isRunning {
            await pollTarget(panel.id)
        }
    }

    private func pollTarget(_ targetID: UUID) async {
        guard let sid = sessions[targetID],
              let panelIndex = panels.firstIndex(where: { $0.id == targetID }) else {
            return
        }

        do {
            let payload = try await callRustWithTimeout(seconds: 8, label: "fetch_stats") {
                orbit_fetch_system_stats(sid)
            }

            let stats = try JSONDecoder().decode(RustSystemStatsPayload.self, from: Data(payload.utf8))
            let point = MonitorPoint(
                time: Date(timeIntervalSince1970: TimeInterval(stats.sampledAtUnix)),
                cpuUsage: stats.cpuUsagePercent,
                memUsedPercent: stats.memUsedPercent,
                diskUsedPercent: stats.diskUsedPercent,
                pingLatencyMs: stats.pingLatencyMs,
                rxRateKBps: stats.rxRateKbps,
                txRateKBps: stats.txRateKbps
            )

            var buffer = buffers[targetID] ?? CircularBuffer(capacity: 600)
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

            if shouldAutoHeal(error: error, failureCount: count) {
                panels[panelIndex].status = "采集中断，后台静默重连中..."
                scheduleSilentReconnect(targetID)
            }
        }
    }

    private func shouldAutoHeal(error: Error, failureCount: Int) -> Bool {
        guard failureCount >= 2 else { return false }
        if case let SFTPError.rustError(message) = error {
            let lower = message.lowercased()
            if lower.contains("auth") || lower.contains("permission denied") || lower.contains("private key") {
                return false
            }
        }
        return true
    }

    private func scheduleSilentReconnect(_ targetID: UUID) {
        guard reconnectTasks[targetID] == nil else { return }

        reconnectTasks[targetID] = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.reconnectTasks[targetID] = nil }

            let backoffSeconds: [UInt64] = [2, 5, 10, 20, 30]
            for sec in backoffSeconds {
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
                target.host.withCString { host in
                    target.username.withCString { user in
                        credentials.password.withCString { password in
                                credentials.privateKeyContent.withCString { k in
                                    credentials.privateKeyPassphrase.withCString { passphrase in
                                        orbit_sftp_connect(
                                            host,
                                            Int32(max(1, min(65535, target.port))),
                                            user,
                                            password,
                                            k,
                                            passphrase,
                                            allowFallback ? 1 : 0
                                        )
                                    }
                                }
                            }
                    }
                }
            }

            guard let newSID = UInt64(payload) else {
                throw SFTPError.invalidResponse
            }

            sessions[targetID] = newSID
            consecutiveFailures[targetID] = 0
            panels[index].status = "监控已恢复"
            logger.debug("[MON] healed target=\(target.name, privacy: .public) sid=\(newSID)")
            return true
        } catch {
            panels[index].status = "重连中..."
            return false
        }
    }

    private func loadTargets() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let targets = try? JSONDecoder().decode([MonitorTargetConfig].self, from: data),
              !targets.isEmpty else {
            let defaultTarget = MonitorTargetConfig(
                name: "Default",
                host: "",
                username: ""
            )
            panels = [MonitorPanelState(id: defaultTarget.id, target: defaultTarget, isRunning: false, status: "请先配置服务器", points: [])]
            buffers[defaultTarget.id] = CircularBuffer(capacity: 600)
            return
        }

        var needsRewrite = false
        if !UserDefaults.standard.bool(forKey: migrationFlagKey) {
            for target in targets {
                let legacy = target.legacyPassword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !legacy.isEmpty {
                    try? vault.save(ServerCredentials(password: legacy, privateKeyContent: ""), for: target.credentialID)
                    needsRewrite = true
                }
            }
            UserDefaults.standard.set(true, forKey: migrationFlagKey)
        }
        if targets.contains(where: { $0.legacyPassword?.isEmpty == false }) {
            needsRewrite = true
        }

        panels = targets.map {
            MonitorPanelState(id: $0.id, target: $0, isRunning: false, status: "未连接", points: [])
        }
        for target in targets {
            buffers[target.id] = CircularBuffer(capacity: 600)
        }

        if needsRewrite {
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
            persistTargets()
        }
    }

    private func persistTargets() {
        let targets = panels.map(\.target)
        if let data = try? JSONEncoder().encode(targets) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    private func callRustWithTimeout(
        seconds: TimeInterval,
        label: String,
        _ call: @escaping () -> UnsafeMutablePointer<CChar>?
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask(priority: .userInitiated) {
                try Self.parseOKPayload(Self.callRust(call))
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SFTPError.timeout
            }

            guard let first = try await group.next() else {
                throw SFTPError.invalidResponse
            }
            group.cancelAll()
            logger.debug("[MON] rust_call=\(label, privacy: .public) bytes=\(first.utf8.count)")
            return first
        }
    }

    private nonisolated static func callRust(_ call: () -> UnsafeMutablePointer<CChar>?) -> String {
        guard let ptr = call() else {
            return "ERR:Rust 返回空指针"
        }
        defer { orbit_free_string(ptr) }
        return String(cString: ptr)
    }

    private nonisolated static func parseOKPayload(_ raw: String) throws -> String {
        if raw.hasPrefix("OK:") { return String(raw.dropFirst(3)) }
        if raw.hasPrefix("ERR:") { throw SFTPError.rustError(String(raw.dropFirst(4))) }
        throw SFTPError.invalidResponse
    }
}
