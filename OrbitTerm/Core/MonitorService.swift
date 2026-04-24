import Foundation
import os

struct MonitorTargetConfig: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var username: String
    var password: String

    init(id: UUID = UUID(), name: String, host: String, username: String, password: String) {
        self.id = id
        self.name = name
        self.host = host
        self.username = username
        self.password = password
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
    private var loopTask: Task<Void, Never>?

    private let userDefaultsKey = "monitor.targets.v1"

    init() {
        loadTargets()
        startBackgroundLoop()
    }

    deinit {
        loopTask?.cancel()
    }

    func addTarget(name: String, host: String, username: String, password: String) {
        let target = MonitorTargetConfig(name: name, host: host, username: username, password: password)
        panels.append(MonitorPanelState(id: target.id, target: target, isRunning: false, status: "未连接", points: []))
        buffers[target.id] = CircularBuffer(capacity: 600)
        persistTargets()
    }

    func removeTarget(_ targetID: UUID) {
        Task { await disconnect(targetID) }
        panels.removeAll { $0.id == targetID }
        buffers.removeValue(forKey: targetID)
        sessions.removeValue(forKey: targetID)
        persistTargets()
    }

    func connect(_ targetID: UUID) async {
        guard let index = panels.firstIndex(where: { $0.id == targetID }) else { return }
        let target = panels[index].target

        do {
            let payload = try await callRustWithTimeout(seconds: 12, label: "connect") {
                target.host.withCString { host in
                    target.username.withCString { user in
                        target.password.withCString { password in
                            orbit_sftp_connect(host, user, password)
                        }
                    }
                }
            }

            guard let sessionID = UInt64(payload) else {
                throw SFTPError.invalidResponse
            }

            sessions[targetID] = sessionID
            panels[index].isRunning = true
            panels[index].status = "监控中"
            logger.debug("[MON] connected target=\(target.name, privacy: .public) sid=\(sessionID)")
        } catch {
            panels[index].status = "连接失败: \(error.localizedDescription)"
            panels[index].isRunning = false
        }
    }

    func disconnect(_ targetID: UUID) async {
        guard let sid = sessions[targetID] else { return }
        _ = try? await callRustWithTimeout(seconds: 8, label: "disconnect") {
            orbit_sftp_disconnect(sid)
        }
        sessions.removeValue(forKey: targetID)
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

            panels[panelIndex].points = buffer.elementsInOrder
            panels[panelIndex].status = "实时监控中"
        } catch {
            panels[panelIndex].status = "采集失败: \(error.localizedDescription)"
            if case SFTPError.timeout = error {
                panels[panelIndex].status = "采集超时，正在重试..."
            }
        }
    }

    private func loadTargets() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let targets = try? JSONDecoder().decode([MonitorTargetConfig].self, from: data),
              !targets.isEmpty else {
            let defaultTarget = MonitorTargetConfig(
                name: "Default",
                host: "",
                username: "",
                password: ""
            )
            panels = [MonitorPanelState(id: defaultTarget.id, target: defaultTarget, isRunning: false, status: "请先配置服务器", points: [])]
            buffers[defaultTarget.id] = CircularBuffer(capacity: 600)
            return
        }

        panels = targets.map {
            MonitorPanelState(id: $0.id, target: $0, isRunning: false, status: "未连接", points: [])
        }
        for target in targets {
            buffers[target.id] = CircularBuffer(capacity: 600)
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
