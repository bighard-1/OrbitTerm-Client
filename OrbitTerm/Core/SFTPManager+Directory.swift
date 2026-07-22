import Foundation

extension SFTPManager {
    func refresh(path: String? = nil) async throws {
        let targetPath = path ?? currentPath

        if isUsingMockData {
            useMockData(path: targetPath, status: "模拟目录：\(targetPath)")
            return
        }

        guard let sid = operationSessionID else { throw SFTPError.notConnected }

        isLoading = true
        defer { isLoading = false }

        items = try await directoryItems(at: targetPath, sessionID: sid)
        currentPath = targetPath
        statusText = "\(items.count) 个项目"
    }

    /// Reads a remote directory without changing the currently displayed path.
    /// File operations use this to walk a directory selected for deletion while
    /// keeping the visible listing stable until the final refresh succeeds.
    func directoryItems(at path: String, sessionID: UInt64) async throws -> [FileItem] {
        let payload = try await RustFFI.runWithTimeout(seconds: 10) {
            try RustFFI.parseOKPayload(
                RustFFI.call {
                    path.withCString { cPath in
                        orbit_sftp_list_dir(sessionID, cPath)
                    }
                }
            )
        }

        debugLog("list_dir_payload", [
            "session": "\(sessionID)",
            "path": path,
            "utf8_bytes": "\(payload.utf8.count)",
            "preview": String(payload.prefix(120))
        ])

        let decoded = try JSONDecoder().decode([FileItem].self, from: Data(payload.utf8))
        return decoded.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
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
}
