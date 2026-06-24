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
    case remove

    var label: String {
        switch self {
        case .start: return "启动"
        case .stop: return "停止"
        case .restart: return "重启"
        case .kill: return "强制终止"
        case .remove: return "删除容器"
        }
    }
}

struct DockerContainerUpdateOptions {
    var restartPolicy: String?
    var memoryLimit: String?
    var cpuShares: Int?
}

@MainActor
final class DockerService: ObservableObject {
    @Published var cards: [DockerContainerCard] = []
    @Published var isConnected: Bool = false
    @Published var isLoading: Bool = false
    @Published var isScanning: Bool = false
    @Published var dockerEnvironmentMissing: Bool = false
    @Published var statusText: String = "未连接"
    @Published private(set) var checkedError: CheckedDockerServiceError?

    private let logger = Logger(subsystem: "com.orbitterm.app", category: "docker")
    private var connectionMode: ConnectionSecurityPolicy = .applicationDefault
    private var checkedOperator: (any CheckedDockerOperating)?
    private var checkedBinding: CheckedDockerBinding?
    private var checkedRefreshLoop: CheckedDockerRefreshLoop?
    private var sessionID: UInt64?
    private var refreshTask: Task<Void, Never>?

    var isRenameUpdateAvailable: Bool {
        connectionMode.allowsLegacyNetwork
    }

    func configureConnectionMode(
        _ mode: ConnectionSecurityPolicy,
        checkedOperator: (any CheckedDockerOperating)? = nil
    ) {
        connectionMode = mode
        self.checkedOperator = checkedOperator
    }

    func connect(
        host: String,
        port: Int = 22,
        username: String,
        password: String,
        privateKeyContent: String = "",
        privateKeyPassphrase: String = "",
        allowPasswordFallback: Bool = true
    ) async {
        guard connectionMode.allowsLegacyNetwork else {
            rejectLegacyDocker()
            return
        }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !username.isEmpty, !(password.isEmpty && key.isEmpty) else {
            statusText = "请填写完整 SSH 连接信息"
            return
        }

        isLoading = true
        isScanning = true
        dockerEnvironmentMissing = false
        statusText = "正在扫描容器..."
        defer { isLoading = false }

        do {
            let payload = try await callRustWithTimeout(seconds: 12) {
                RustFFI.connectSFTP(
                    host: host,
                    port: port,
                    username: username,
                    password: password,
                    privateKeyContent: key,
                    privateKeyPassphrase: privateKeyPassphrase,
                    allowPasswordFallback: allowPasswordFallback
                )
            }

            guard let sid = UInt64(payload) else {
                throw SFTPError.invalidResponse
            }

            sessionID = sid
            isConnected = true
            statusText = "正在扫描容器..."
            startRefreshLoop()
            try await refreshNow()
            isScanning = false
        } catch {
            isScanning = false
            let message = error.localizedDescription.lowercased()
            if message.contains("docker") || message.contains("command") || message.contains("not found") {
                dockerEnvironmentMissing = true
                statusText = "未检测到 Docker 环境"
            } else {
                dockerEnvironmentMissing = false
                statusText = "连接失败: \(error.localizedDescription)"
            }
            isConnected = false
            sessionID = nil
        }
    }

    func connect(baseSessionID: UInt64) async {
        guard connectionMode.allowsLegacyNetwork else {
            rejectLegacyDocker()
            return
        }
        isLoading = true
        isScanning = true
        dockerEnvironmentMissing = false
        statusText = "正在扫描容器..."
        defer { isLoading = false }

        do {
            let payload = try await callRustWithTimeout(seconds: 8) {
                RustFFI.requestChannel(baseSessionID: baseSessionID, type: "sftp")
            }

            guard let sid = UInt64(payload) else {
                throw SFTPError.invalidResponse
            }

            sessionID = sid
            isConnected = true
            statusText = "正在扫描容器..."
            startRefreshLoop()
            try await refreshNow()
            isScanning = false
        } catch {
            isScanning = false
            let message = error.localizedDescription.lowercased()
            if message.contains("docker") || message.contains("command") || message.contains("not found") {
                dockerEnvironmentMissing = true
                statusText = "未检测到 Docker 环境"
            } else {
                dockerEnvironmentMissing = false
                statusText = "连接失败: \(error.localizedDescription)"
            }
            isConnected = false
            sessionID = nil
        }
    }

    func disconnect() async {
        if connectionMode.requiresCheckedNetwork {
            await checkedRefreshLoop?.stop()
            checkedRefreshLoop = nil
            checkedBinding = nil
            sessionID = nil
            checkedError = nil
            cards = []
            isConnected = false
            isScanning = false
            dockerEnvironmentMissing = false
            statusText = "已断开"
            return
        }
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
        isScanning = false
        dockerEnvironmentMissing = false
        statusText = "已断开"
    }

    func refreshNow() async throws {
        if connectionMode.requiresCheckedNetwork {
            guard let binding = checkedBinding else {
                throw CheckedDockerServiceError.requiresVerifiedSession
            }
            guard let checkedOperator else {
                throw CheckedDockerServiceError.internalInvariant
            }
            do {
                let refresh = try await checkedOperator.refresh(binding: binding)
                applyCheckedRefresh(refresh)
                return
            } catch let error as CheckedDockerServiceError {
                handleCheckedFailure(error)
                throw error
            } catch {
                let mapped = CheckedDockerServiceError.unknownCheckedFFIError
                handleCheckedFailure(mapped)
                throw mapped
            }
        }
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
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
        isScanning = false
        dockerEnvironmentMissing = false
        logger.debug("[DOCKER] refresh cards=\(self.cards.count)")
        #else
        throw CheckedDockerServiceError.legacyDockerDisabledInCheckedMode
        #endif
    }

    func performAction(containerID: String, action: DockerAction) async {
        if connectionMode.requiresCheckedNetwork {
            guard let binding = checkedBinding else {
                handleCheckedFailure(.requiresVerifiedSession)
                return
            }
            guard let checkedOperator, let checkedAction = action.checkedAction else {
                handleCheckedFailure(.invalidDockerAction)
                return
            }
            do {
                _ = try await checkedOperator.perform(
                    binding: binding,
                    containerID: containerID,
                    action: checkedAction
                )
                try await refreshNow()
            } catch let error as CheckedDockerServiceError {
                handleCheckedFailure(error)
            } catch {
                handleCheckedFailure(.unknownCheckedFFIError)
            }
            return
        }
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
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
        #endif
    }

    func fetchLogs(containerID: String, tailLines: UInt32 = 300) async throws -> String {
        if connectionMode.requiresCheckedNetwork {
            guard let binding = checkedBinding else {
                throw CheckedDockerServiceError.requiresVerifiedSession
            }
            guard let checkedOperator else {
                throw CheckedDockerServiceError.internalInvariant
            }
            do {
                let payload = try await checkedOperator.logs(
                    binding: binding,
                    containerID: containerID,
                    tail: tailLines
                )
                return payload.logs
            } catch let error as CheckedDockerServiceError {
                if error == .sessionClosed {
                    handleCheckedFailure(error)
                }
                throw error
            }
        }
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        guard let sid = sessionID else { throw SFTPError.notConnected }
        return try await callRustWithTimeout(seconds: 10) {
            containerID.withCString { cID in
                orbit_fetch_docker_logs(sid, cID, tailLines)
            }
        }
        #else
        throw CheckedDockerServiceError.legacyDockerDisabledInCheckedMode
        #endif
    }

    func renameContainer(containerID: String, newName: String) async {
        guard connectionMode.allowsLegacyNetwork else {
            handleCheckedFailure(.renameUpdateDisabledInCheckedMode, disconnect: false)
            return
        }
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        guard let sid = sessionID else { return }
        let targetName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetName.isEmpty else { return }
        do {
            let cmd = "docker rename \(containerID) \(targetName)"
            _ = try await callRustWithTimeout(seconds: 12) {
                cmd.withCString { cCmd in
                    orbit_exec_command(sid, cCmd)
                }
            }
            try await refreshNow()
        } catch {
            statusText = "编辑失败: \(error.localizedDescription)"
        }
        #endif
    }

    func updateContainer(containerID: String, options: DockerContainerUpdateOptions) async {
        guard connectionMode.allowsLegacyNetwork else {
            handleCheckedFailure(.renameUpdateDisabledInCheckedMode, disconnect: false)
            return
        }
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        guard let sid = sessionID else { return }
        var parts: [String] = ["docker", "update"]
        if let policy = options.restartPolicy?.trimmingCharacters(in: .whitespacesAndNewlines), !policy.isEmpty {
            parts.append("--restart=\(policy)")
        }
        if let mem = options.memoryLimit?.trimmingCharacters(in: .whitespacesAndNewlines), !mem.isEmpty {
            parts.append("--memory=\(mem)")
        }
        if let shares = options.cpuShares, shares > 0 {
            parts.append("--cpu-shares=\(shares)")
        }
        parts.append(containerID)
        guard parts.count > 2 else { return }
        let cmd = parts.joined(separator: " ")
        do {
            _ = try await callRustWithTimeout(seconds: 12) {
                cmd.withCString { cCmd in
                    orbit_exec_command(sid, cCmd)
                }
            }
            try await refreshNow()
        } catch {
            statusText = "更新失败: \(error.localizedDescription)"
        }
        #endif
    }

    private func startRefreshLoop() {
        guard connectionMode.allowsLegacyNetwork else { return }
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
        _ call: @escaping @Sendable () -> UnsafeMutablePointer<CChar>?
    ) async throws -> String {
        try await RustFFI.callWithTimeout(seconds: seconds, call)
    }

    func startCheckedDocker(
        workspaceID: UUID,
        baseSessionID: BaseSessionID
    ) async -> Result<Void, CheckedDockerServiceError> {
        guard connectionMode.requiresCheckedNetwork else {
            return .failure(.legacyDockerDisabledInCheckedMode)
        }
        guard let checkedOperator else {
            return .failure(.internalInvariant)
        }

        await checkedRefreshLoop?.stop()
        let binding = CheckedDockerBinding(
            workspaceID: workspaceID,
            baseSessionID: baseSessionID
        )
        checkedBinding = binding
        checkedError = nil
        isLoading = true
        isScanning = true
        statusText = "正在安全扫描容器..."

        do {
            let refresh = try await checkedOperator.refresh(binding: binding)
            applyCheckedRefresh(refresh)
            let loop = CheckedDockerRefreshLoop(
                binding: binding,
                operatorService: checkedOperator,
                intervalNanoseconds: 2_000_000_000
            )
            checkedRefreshLoop = loop
            await loop.start { [weak self] result in
                await self?.applyCheckedRefreshResult(result)
            }
            isLoading = false
            return .success(())
        } catch let error as CheckedDockerServiceError {
            isLoading = false
            handleCheckedFailure(error)
            return .failure(error)
        } catch {
            isLoading = false
            let mapped = CheckedDockerServiceError.unknownCheckedFFIError
            handleCheckedFailure(mapped)
            return .failure(mapped)
        }
    }

    func rejectCheckedStandalone(
        _ error: CheckedDockerServiceError = .requiresVerifiedSession
    ) {
        checkedError = error
        isConnected = false
        isScanning = false
        statusText = error.userMessage
    }

    func currentCheckedBinding() -> CheckedDockerBinding? {
        checkedBinding
    }

    private func applyCheckedRefresh(_ refresh: CheckedDockerRefresh) {
        let statsMap = Dictionary(uniqueKeysWithValues: refresh.stats.stats.map { ($0.id, $0) })
        cards = refresh.containers.containers.map { container in
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
        checkedError = nil
        isConnected = true
        isScanning = false
        dockerEnvironmentMissing = false
        statusText = "\(cards.count) 个容器（已验证）"
    }

    private func applyCheckedRefreshResult(
        _ result: Result<CheckedDockerRefresh, CheckedDockerServiceError>
    ) {
        guard checkedBinding != nil else { return }
        switch result {
        case let .success(refresh):
            applyCheckedRefresh(refresh)
        case let .failure(error):
            handleCheckedFailure(error)
        }
    }

    private func handleCheckedFailure(
        _ error: CheckedDockerServiceError,
        disconnect: Bool = true
    ) {
        checkedError = error
        isScanning = false
        statusText = error.userMessage
        if disconnect {
            isConnected = false
            let loop = checkedRefreshLoop
            checkedRefreshLoop = nil
            Task { await loop?.stop() }
        }
    }

    private func rejectLegacyDocker() {
        handleCheckedFailure(.legacyDockerDisabledInCheckedMode)
    }
}

private extension DockerAction {
    var checkedAction: CheckedDockerAction? {
        CheckedDockerAction(rawValue: rawValue)
    }
}
