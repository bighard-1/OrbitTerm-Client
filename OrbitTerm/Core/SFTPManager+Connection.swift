import Foundation

extension SFTPManager {
    func activateMockIfNeeded(host: String, username: String, password: String) {
        #if !ORBITTERM_PUBLIC_RELEASE
        guard host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              password.isEmpty,
              !isConnected else {
            return
        }

        useMockData(path: "/", status: "当前为模拟模式（未配置服务器）")
        isConnected = true
        #else
        // Mock browsing is deliberately unavailable in public builds.
        _ = (host, username, password)
        #endif
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
        invalidateConnectionOperations()
        guard allowsLegacyConnection else {
            rejectCheckedStandalone(.legacySFTPDisabledInCheckedMode)
            return
        }
        checkedConnection = nil
        checkedError = nil
        let cleanedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedKey = privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines)

        #if !ORBITTERM_PUBLIC_RELEASE
        if preferMock || cleanedHost.isEmpty || cleanedUsername.isEmpty || (password.isEmpty && cleanedKey.isEmpty) {
            useMockData(path: "/", status: "当前为模拟模式")
            isConnected = true
            debugLog("switch_to_mock", ["host": cleanedHost, "username": cleanedUsername])
            return
        }
        #else
        guard !preferMock,
              !cleanedHost.isEmpty,
              !cleanedUsername.isEmpty,
              !(password.isEmpty && cleanedKey.isEmpty) else {
            checkedConnection = nil
            checkedError = nil
            isUsingMockData = false
            isConnected = false
            statusText = "请配置 SSH 主机、用户名和认证信息"
            return
        }
        #endif

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
            _ = beginConnectionOperation(scope: .terminalChannel(sid))
            isUsingMockData = false
            isConnected = true
            establishTransferConnectionScope(sessionID: sid)
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
        invalidateConnectionOperations()
        guard allowsLegacyConnection else {
            rejectCheckedStandalone(.legacySFTPDisabledInCheckedMode)
            return
        }
        checkedConnection = nil
        checkedError = nil
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
            _ = beginConnectionOperation(scope: .terminalChannel(sid))
            isUsingMockData = false
            isConnected = true
            establishTransferConnectionScope(sessionID: sid)
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

    @discardableResult
    func connectChecked(
        workspaceID: UUID,
        baseSessionID: BaseSessionID,
        opener: any CheckedSFTPConnectionOpening,
        initialPath: String = "/"
    ) async -> Result<CheckedSFTPConnection, CheckedSFTPServiceError> {
        let operationLease = beginConnectionOperation(scope: .workspace(workspaceID))
        isLoading = true
        defer { isLoading = false }

        do {
            let connection = try await opener.open(
                workspaceID: workspaceID,
                baseSessionID: baseSessionID
            )
            guard connection.workspaceID == workspaceID,
                  connection.baseSessionID == baseSessionID else {
                throw CheckedSFTPServiceError.internalInvariant
            }

            guard acceptsConnectionOperation(operationLease, scope: .workspace(workspaceID)) else {
                await closeCheckedChannel(connection)
                return .failure(.sessionClosed)
            }

            sessionID = nil
            checkedConnection = connection
            checkedError = nil
            isUsingMockData = false
            isConnected = true
            establishTransferConnectionScope(sessionID: connection.sftpSessionID.ffiValue)
            statusText = "已从验证会话打开 SFTP"
            let resolvedHome = connection.homePath.hasPrefix("/") ? connection.homePath : initialPath
            try await refreshInitialDirectory(preferredPath: resolvedHome)
            guard acceptsConnectionOperation(operationLease, scope: .workspace(workspaceID)),
                  checkedConnection == connection else {
                await closeCheckedChannel(connection)
                return .failure(.sessionClosed)
            }
            successHaptic()
            return .success(connection)
        } catch let error as CheckedSFTPServiceError {
            await closeCheckedChannelAfterFailedOpen()
            invalidateTransferOperations()
            checkedConnection = nil
            checkedError = error
            isConnected = false
            statusText = error.userMessage
            return .failure(error)
        } catch {
            await closeCheckedChannelAfterFailedOpen()
            invalidateTransferOperations()
            let mapped = CheckedSFTPServiceError.unknownCheckedFFIError
            checkedConnection = nil
            checkedError = mapped
            isConnected = false
            statusText = mapped.userMessage
            return .failure(mapped)
        }
    }

    private func refreshInitialDirectory(preferredPath: String) async throws {
        do {
            try await refresh(path: preferredPath)
        } catch {
            guard preferredPath != "/" else { throw error }
            try await refresh(path: "/")
            statusText = "用户主目录不可用，已打开根目录；新建项请选择有写入权限的位置"
        }
    }

    private func closeCheckedChannelAfterFailedOpen() async {
        guard let sid = operationSessionID, checkedConnection != nil else { return }
        _ = try? await RustFFI.runWithTimeout(seconds: 8) {
            try RustFFI.parseOKPayload(RustFFI.call { orbit_sftp_disconnect(sid) })
        }
    }

    private func closeCheckedChannel(_ connection: CheckedSFTPConnection) async {
        _ = try? await RustFFI.runWithTimeout(seconds: 8) {
            try RustFFI.parseOKPayload(
                RustFFI.call { orbit_sftp_disconnect(connection.sftpSessionID.ffiValue) }
            )
        }
    }

    func disconnect() async {
        invalidateDirectoryLoads()
        invalidateTransferOperations()
        invalidateConnectionOperations()
        if isUsingMockData {
            items = []
            isConnected = false
            currentPath = "/"
            statusText = "已断开"
            return
        }

        guard let sid = operationSessionID else { return }
        _ = try? await RustFFI.runWithTimeout(seconds: 8) {
            try RustFFI.parseOKPayload(RustFFI.call { orbit_sftp_disconnect(sid) })
        }
        isConnected = false
        sessionID = nil
        checkedConnection = nil
        checkedError = nil
        items = []
        currentPath = "/"
        statusText = "已断开"
    }
}
