import Foundation

extension SFTPManager {
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
            let sessionPayload = try await RustFFI.runWithTimeout(seconds: 12) {
                try RustFFI.parseOKPayload(
                    RustFFI.call {
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
            let sessionPayload = try await RustFFI.runWithTimeout(seconds: 8) {
                try RustFFI.parseOKPayload(
                    RustFFI.call {
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
        _ = try? await RustFFI.runWithTimeout(seconds: 8) {
            try RustFFI.parseOKPayload(RustFFI.call { orbit_sftp_disconnect(sid) })
        }
        isConnected = false
        sessionID = nil
        items = []
        currentPath = "/"
        statusText = "已断开"
    }
}
