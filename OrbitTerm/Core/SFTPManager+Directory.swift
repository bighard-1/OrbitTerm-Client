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

        let payload = try await RustFFI.runWithTimeout(seconds: 10) {
            try RustFFI.parseOKPayload(
                RustFFI.call {
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
}
