import Foundation
import os

struct DockerContainerItem: Identifiable, Decodable, Hashable {
    var id: String
    let name: String
    let image: String
    let state: String
    let status: String
    let runningFor: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case image
        case state
        case status
        case runningFor = "running_for"
    }

    var isRunning: Bool {
        let s = state.lowercased()
        return s == "running" || status.lowercased().contains("up")
    }
}

struct DockerStatsItem: Decodable, Hashable {
    let id: String
    let name: String
    let cpuPercent: Double
    let memPercent: Double
    let memUsage: String
    let netIO: String
    let blockIO: String
    let pids: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case cpuPercent = "cpu_percent"
        case memPercent = "mem_percent"
        case memUsage = "mem_usage"
        case netIO = "net_io"
        case blockIO = "block_io"
        case pids
    }
}

struct DockerContainerCard: Identifiable, Hashable {
    let id: String
    let name: String
    let image: String
    let state: String
    let status: String
    let runningFor: String
    let cpuPercent: Double
    let memPercent: Double
    let memUsage: String

    var isRunning: Bool {
        let lower = state.lowercased()
        return lower == "running" || status.lowercased().contains("up")
    }
}

enum DockerAction: String, CaseIterable {
    case start
    case stop
    case restart
    case kill

    var label: String {
        switch self {
        case .start: return "启动"
        case .stop: return "停止"
        case .restart: return "重启"
        case .kill: return "强制终止"
        }
    }
}

@MainActor
final class DockerService: ObservableObject {
    @Published var cards: [DockerContainerCard] = []
    @Published var isConnected: Bool = false
    @Published var isLoading: Bool = false
    @Published var statusText: String = "未连接"

    private let logger = Logger(subsystem: "com.orbitterm.app", category: "docker")
    private var sessionID: UInt64?
    private var refreshTask: Task<Void, Never>?

    func connect(host: String, username: String, password: String) async {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !username.isEmpty, !password.isEmpty else {
            statusText = "请填写完整 SSH 连接信息"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let payload = try await callRustWithTimeout(seconds: 12) {
                host.withCString { h in
                    username.withCString { u in
                        password.withCString { p in
                            orbit_sftp_connect(h, u, p)
                        }
                    }
                }
            }

            guard let sid = UInt64(payload) else {
                throw SFTPError.invalidResponse
            }

            sessionID = sid
            isConnected = true
            statusText = "Docker 已连接"
            startRefreshLoop()
            try await refreshNow()
        } catch {
            statusText = "连接失败: \(error.localizedDescription)"
            isConnected = false
            sessionID = nil
        }
    }

    func disconnect() async {
        refreshTask?.cancel()
        refreshTask = nil

        guard let sid = sessionID else {
            isConnected = false
            return
        }

        _ = try? await callRustWithTimeout(seconds: 8) {
            orbit_sftp_disconnect(sid)
        }

        sessionID = nil
        cards = []
        isConnected = false
        statusText = "已断开"
    }

    func refreshNow() async throws {
        guard let sid = sessionID else { throw SFTPError.notConnected }

        let containersPayload = try await callRustWithTimeout(seconds: 10) {
            orbit_fetch_docker_containers(sid)
        }
        let statsPayload = try await callRustWithTimeout(seconds: 10) {
            orbit_fetch_docker_stats(sid)
        }

        let containers = try JSONDecoder().decode([DockerContainerItem].self, from: Data(containersPayload.utf8))
        let stats = try JSONDecoder().decode([DockerStatsItem].self, from: Data(statsPayload.utf8))
        let statsMap = Dictionary(uniqueKeysWithValues: stats.map { ($0.id, $0) })

        cards = containers.map { container in
            let stat = statsMap[container.id]
            return DockerContainerCard(
                id: container.id,
                name: container.name,
                image: container.image,
                state: container.state,
                status: container.status,
                runningFor: container.runningFor,
                cpuPercent: stat?.cpuPercent ?? 0,
                memPercent: stat?.memPercent ?? 0,
                memUsage: stat?.memUsage ?? "-"
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        statusText = "\(cards.count) 个容器"
        logger.debug("[DOCKER] refresh cards=\(self.cards.count)")
    }

    func performAction(containerID: String, action: DockerAction) async {
        guard let sid = sessionID else { return }
        do {
            _ = try await callRustWithTimeout(seconds: 12) {
                containerID.withCString { cID in
                    action.rawValue.withCString { actionC in
                        orbit_docker_action(sid, cID, actionC)
                    }
                }
            }
            try await refreshNow()
        } catch {
            statusText = "操作失败: \(error.localizedDescription)"
        }
    }

    func fetchLogs(containerID: String, tailLines: UInt32 = 300) async throws -> String {
        guard let sid = sessionID else { throw SFTPError.notConnected }
        return try await callRustWithTimeout(seconds: 10) {
            containerID.withCString { cID in
                orbit_fetch_docker_logs(sid, cID, tailLines)
            }
        }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.refreshNow()
                } catch {
                    self.statusText = "刷新失败: \(error.localizedDescription)"
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func callRustWithTimeout(
        seconds: TimeInterval,
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
        if raw.hasPrefix("OK:") {
            return String(raw.dropFirst(3))
        }
        if raw.hasPrefix("ERR:") {
            throw SFTPError.rustError(String(raw.dropFirst(4)))
        }
        throw SFTPError.invalidResponse
    }
}
