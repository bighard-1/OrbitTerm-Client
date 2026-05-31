import Foundation
import os

@MainActor
final class SFTPManager: ObservableObject {
    @Published var items: [FileItem] = []
    @Published var currentPath: String = "/"
    @Published var isConnected: Bool = false
    @Published var isLoading: Bool = false
    @Published var statusText: String = "未连接"
    @Published var transfers: [TransferTaskItem] = []
    @Published var isUsingMockData: Bool = false

    private let logger = Logger(subsystem: "com.orbitterm.app", category: "sftp")
    private(set) var sessionID: UInt64?

    var activeSessionID: UInt64? { sessionID }

    func activateMockIfNeeded(host: String, username: String, password: String) {
        guard host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              password.isEmpty,
              !isConnected else {
            return
        }

        useMockData(path: "/", status: "当前为模拟模式（未配置服务器）")
        isConnected = true
    }

    func connect(
        host: String,
        port: Int = 22,
        username: String,
        password: String,
        privateKeyContent: String = "",
        privateKeyPassphrase: String = "",
        allowPasswordFallback: Bool = true,
        preferMock: Bool = false
    ) async {
        let cleanedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedKey = privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines)

        if preferMock || cleanedHost.isEmpty || cleanedUsername.isEmpty || (password.isEmpty && cleanedKey.isEmpty) {
            useMockData(path: "/", status: "当前为模拟模式")
            isConnected = true
            debugLog("switch_to_mock", ["host": cleanedHost, "username": cleanedUsername])
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let sessionPayload = try await runBlockingWithTimeout(seconds: 12) {
                try Self.parseOKPayload(
                    Self.callRust {
                        RustFFI.connectSFTP(
                            host: cleanedHost,
                            port: port,
                            username: cleanedUsername,
                            password: password,
                            privateKeyContent: cleanedKey,
                            privateKeyPassphrase: privateKeyPassphrase,
                            allowPasswordFallback: allowPasswordFallback
                        )
                    }
                )
            }

            guard let sid = UInt64(sessionPayload) else {
                throw SFTPError.invalidResponse
            }

            sessionID = sid
            isUsingMockData = false
            isConnected = true
            statusText = "已连接"
            debugLog("connect_ok", ["session": "\(sid)"])
            try await refresh(path: "/")
            successHaptic()
        } catch {
            statusText = "连接失败: \(error.localizedDescription)"
            isConnected = false
            sessionID = nil
            debugLog("connect_failed", ["error": error.localizedDescription])
        }
    }

    func connect(baseSessionID: UInt64, initialPath: String = "/") async {
        isLoading = true
        defer { isLoading = false }

        do {
            let sessionPayload = try await runBlockingWithTimeout(seconds: 8) {
                try Self.parseOKPayload(
                    Self.callRust {
                        RustFFI.requestChannel(baseSessionID: baseSessionID, type: "sftp")
                    }
                )
            }

            guard let sid = UInt64(sessionPayload) else {
                throw SFTPError.invalidResponse
            }

            sessionID = sid
            isUsingMockData = false
            isConnected = true
            statusText = "已复用 SSH 会话"
            debugLog("connect_reuse_ok", ["base": "\(baseSessionID)", "session": "\(sid)"])
            try await refresh(path: initialPath)
            successHaptic()
        } catch {
            statusText = "连接失败: \(error.localizedDescription)"
            isConnected = false
            sessionID = nil
            debugLog("connect_reuse_failed", ["base": "\(baseSessionID)", "error": error.localizedDescription])
        }
    }

    func disconnect() async {
        if isUsingMockData {
            items = []
            isConnected = false
            currentPath = "/"
            statusText = "已断开"
            return
        }

        guard let sid = sessionID else { return }
        _ = try? await runBlockingWithTimeout(seconds: 8) {
            try Self.parseOKPayload(Self.callRust { orbit_sftp_disconnect(sid) })
        }
        isConnected = false
        sessionID = nil
        items = []
        currentPath = "/"
        statusText = "已断开"
    }

    func refresh(path: String? = nil) async throws {
        let targetPath = path ?? currentPath

        if isUsingMockData {
            useMockData(path: targetPath, status: "模拟目录：\(targetPath)")
            return
        }

        guard let sid = sessionID else { throw SFTPError.notConnected }

        isLoading = true
        defer { isLoading = false }

        let payload = try await runBlockingWithTimeout(seconds: 10) {
            try Self.parseOKPayload(
                Self.callRust {
                    targetPath.withCString { cPath in
                        orbit_sftp_list_dir(sid, cPath)
                    }
                }
            )
        }

        debugLog("list_dir_payload", [
            "session": "\(sid)",
            "path": targetPath,
            "utf8_bytes": "\(payload.utf8.count)",
            "preview": String(payload.prefix(120))
        ])

        let decoded = try JSONDecoder().decode([FileItem].self, from: Data(payload.utf8))
        items = decoded.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        currentPath = targetPath
        statusText = "\(items.count) 个项目"
    }

    func enterDirectory(_ item: FileItem) async {
        guard item.isDirectory else { return }
        let nextPath = makeChildPath(name: item.name)
        do {
            try await refresh(path: nextPath)
        } catch {
            statusText = "进入目录失败: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func goToPath(_ path: String, reportErrors: Bool = true) async -> Bool {
        do {
            try await refresh(path: path)
            return true
        } catch {
            if reportErrors {
                statusText = "路径跳转失败: \(error.localizedDescription)"
            }
            return false
        }
    }

    func makeChildPath(name: String) -> String {
        if currentPath == "/" {
            return "/\(name)"
        }
        return currentPath + "/" + name
    }

    private func runBlockingWithTimeout<T>(seconds: TimeInterval, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await RustFFI.runWithTimeout(seconds: seconds, work)
    }

    private func useMockData(path: String, status: String) {
        isUsingMockData = true
        currentPath = path
        items = Self.mockItems(path: path)
        statusText = status
        debugLog("mock_items", ["path": path, "count": "\(items.count)"])
    }

    func debugLog(_ event: String, _ fields: [String: String]) {
        let text = fields
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
        logger.debug("[SFTP] \(event, privacy: .public) \(text, privacy: .public)")
    }

    private nonisolated static func callRust(_ call: () -> UnsafeMutablePointer<CChar>?) -> String {
        RustFFI.call(call)
    }

    private nonisolated static func parseOKPayload(_ raw: String) throws -> String {
        try RustFFI.parseOKPayload(raw)
    }

}
