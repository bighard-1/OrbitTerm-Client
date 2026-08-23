import Foundation

extension SFTPManager {
    func refresh(path: String? = nil) async throws {
        let targetPath = path ?? currentPath

        if isUsingMockData {
            useMockData(path: targetPath, status: "模拟目录：\(targetPath)")
            return
        }

        guard let sid = operationSessionID else { throw SFTPError.notConnected }
        let generation = beginDirectoryLoad()
        let span = PerformanceSignpost.begin(.sftpDirectoryRefresh)

        isLoading = true
        defer { finishDirectoryLoad(generation) }

        do {
            let loadedItems = try await directoryItems(at: targetPath, sessionID: sid)
            // A slow response for the previous folder/session is intentionally
            // discarded instead of overwriting the folder the user navigated to.
            guard isCurrentDirectoryLoad(generation, sessionID: sid) else {
                span.cancel()
                return
            }
            items = loadedItems
            currentPath = targetPath
            highlightedItemID = nil
            statusText = "\(items.count) 个项目"
            span.finish()
        } catch {
            span.cancel()
            // Do not surface an error belonging to a folder/session that is no
            // longer current; callers may otherwise overwrite the new status.
            guard isCurrentDirectoryLoad(generation, sessionID: sid) else { return }
            throw error
        }
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

    /// Opens an absolute or current-directory-relative remote path. A file
    /// target is resolved by opening its parent directory and highlighting the
    /// resulting row; a directory target becomes the current directory.
    /// This performs no file transfer and does not alter the SFTP connection.
    @discardableResult
    func navigateToPath(_ rawPath: String) async -> Bool {
        guard let targetPath = normalizedRemotePath(rawPath) else {
            statusText = "请输入有效的远程路径"
            return false
        }

        do {
            try await refresh(path: targetPath)
            return true
        } catch {
            let parentPath = remoteParentPath(of: targetPath)
            let targetName = remoteLastPathComponent(of: targetPath)
            guard parentPath != targetPath, !targetName.isEmpty else {
                statusText = "路径跳转失败: \(error.localizedDescription)"
                return false
            }

            do {
                try await refresh(path: parentPath)
                guard let item = items.first(where: { $0.name == targetName }) else {
                    statusText = "未找到目标文件或目录"
                    return false
                }
                highlightedItemID = item.id
                statusText = "已定位：\(item.name)"
                return true
            } catch {
                statusText = "路径跳转失败: \(error.localizedDescription)"
                return false
            }
        }
    }

    private func normalizedRemotePath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\u{0}") else { return nil }

        let source = trimmed.hasPrefix("/") ? trimmed : makeChildPath(name: trimmed)
        var components: [String] = []
        for component in source.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(String(component))
            }
        }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    private func remoteParentPath(of path: String) -> String {
        guard path != "/" else { return "/" }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return "/" }
        return "/" + components.dropLast().joined(separator: "/")
    }

    private func remoteLastPathComponent(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
    }
}
