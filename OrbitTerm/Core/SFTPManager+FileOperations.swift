import Foundation

extension SFTPManager {
    func rename(item: FileItem, to newName: String) async {
        let cleaned = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            statusText = "重命名失败: 新名称为空"
            return
        }

        if isUsingMockData {
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx] = FileItem(name: cleaned, size: item.size, permissions: item.permissions, permissionsOctal: item.permissionsOctal, modifiedAtUnix: UInt64(Date().timeIntervalSince1970))
                statusText = "模拟模式：已重命名"
                successHaptic()
            }
            return
        }

        guard let sid = operationSessionID else {
            statusText = "重命名失败: 未连接"
            return
        }

        let oldPath = makeChildPath(name: item.name)
        let newPath = makeChildPath(name: cleaned)

        do {
            _ = try await RustFFI.runWithTimeout(seconds: 10) {
                try RustFFI.parseOKPayload(
                    RustFFI.call {
                        oldPath.withCString { oldC in
                            newPath.withCString { newC in
                                orbit_sftp_rename(sid, oldC, newC)
                            }
                        }
                    }
                )
            }
            try await refresh(path: currentPath)
            successHaptic()
        } catch {
            statusText = "重命名失败: \(error.localizedDescription)"
        }
    }

    func createDirectory(named name: String) async {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            statusText = "新建目录失败: 名称为空"
            return
        }
        guard let sid = operationSessionID else {
            statusText = "新建目录失败: 未连接"
            return
        }

        let path = makeChildPath(name: cleaned)
        do {
            _ = try await RustFFI.runWithTimeout(seconds: 10) {
                try RustFFI.parseOKPayload(
                    RustFFI.call {
                        path.withCString { cPath in
                            orbit_sftp_mkdir(sid, cPath)
                        }
                    }
                )
            }
            try await refresh(path: currentPath)
            statusText = "目录已创建"
            successHaptic()
        } catch {
            statusText = "新建目录失败: \(error.localizedDescription)"
        }
    }

    func createFile(named name: String) async {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            statusText = "新建文件失败: 名称为空"
            return
        }
        guard let sid = operationSessionID else {
            statusText = "新建文件失败: 未连接"
            return
        }

        let path = makeChildPath(name: cleaned)
        do {
            _ = try await RustFFI.runWithTimeout(seconds: 10) {
                try RustFFI.parseOKPayload(
                    RustFFI.call {
                        path.withCString { cPath in
                            orbit_sftp_create_file(sid, cPath)
                        }
                    }
                )
            }
            try await refresh(path: currentPath)
            statusText = "文件已创建"
            successHaptic()
        } catch {
            statusText = "新建文件失败: \(error.localizedDescription)"
        }
    }

    func chmod(item: FileItem, modeOctal: String) async {
        let mode = modeOctal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode.range(of: #"^[0-7]{3,4}$"#, options: .regularExpression) != nil else {
            statusText = "修改权限失败: 模式需为 3-4 位八进制"
            return
        }
        guard let sid = operationSessionID else {
            statusText = "修改权限失败: 未连接"
            return
        }

        let path = makeChildPath(name: item.name)
        do {
            _ = try await RustFFI.runWithTimeout(seconds: 10) {
                try RustFFI.parseOKPayload(
                    RustFFI.call {
                        path.withCString { cPath in
                            mode.withCString { cMode in
                                orbit_sftp_chmod(sid, cPath, cMode)
                            }
                        }
                    }
                )
            }
            try await refresh(path: currentPath)
            statusText = "权限已更新为 \(mode)"
            successHaptic()
        } catch {
            statusText = "修改权限失败: \(error.localizedDescription)"
        }
    }

    func readTextFile(item: FileItem) async throws -> String {
        guard !item.isDirectory else {
            throw SFTPError.rustError("目录不支持在线编辑")
        }
        guard let sid = operationSessionID else {
            throw SFTPError.notConnected
        }
        let path = makeChildPath(name: item.name)
        return try await RustFFI.runWithTimeout(seconds: 12) {
            try RustFFI.parseOKPayload(
                RustFFI.call {
                    path.withCString { cPath in
                        orbit_sftp_read_text_file(sid, cPath)
                    }
                }
            )
        }
    }

    func writeTextFile(item: FileItem, content: String) async throws {
        guard !item.isDirectory else {
            throw SFTPError.rustError("目录不支持保存文本")
        }
        guard let sid = operationSessionID else {
            throw SFTPError.notConnected
        }
        let path = makeChildPath(name: item.name)
        _ = try await RustFFI.runWithTimeout(seconds: 15) {
            try RustFFI.parseOKPayload(
                RustFFI.call {
                    path.withCString { cPath in
                        content.withCString { cContent in
                            orbit_sftp_write_text_file(sid, cPath, cContent)
                        }
                    }
                }
            )
        }
        try await refresh(path: currentPath)
        statusText = "文件已保存"
        successHaptic()
    }

    func delete(item: FileItem) async {
        if isUsingMockData {
            items.removeAll { $0.id == item.id }
            statusText = "模拟模式：已删除 \(item.name)"
            successHaptic()
            return
        }
        guard let sid = operationSessionID else {
            statusText = "删除失败: 未连接"
            return
        }

        let remotePath = makeChildPath(name: item.name)
        do {
            _ = try await RustFFI.runWithTimeout(seconds: 10) {
                try RustFFI.parseOKPayload(
                    RustFFI.call {
                        remotePath.withCString { path in
                            orbit_sftp_remove_file(sid, path)
                        }
                    }
                )
            }
            try await refresh(path: currentPath)
            successHaptic()
        } catch {
            statusText = "删除失败: \(error.localizedDescription)"
        }
    }

    func batchDelete(paths: [String]) async -> BatchOperationSummary {
        let uniquePaths = Array(Set(paths)).sorted()
        guard !uniquePaths.isEmpty else { return BatchOperationSummary() }

        if isUsingMockData {
            let names = Set(uniquePaths.map { URL(fileURLWithPath: $0).lastPathComponent })
            let before = items.count
            items.removeAll { names.contains($0.name) }
            let removed = before - items.count
            statusText = "模拟模式：已删除 \(removed) 项"
            return BatchOperationSummary(succeeded: uniquePaths, failed: [:])
        }

        guard let sid = operationSessionID else {
            let failed = Dictionary(uniqueKeysWithValues: uniquePaths.map { ($0, "未连接") })
            statusText = "批量删除失败: 未连接"
            return BatchOperationSummary(succeeded: [], failed: failed)
        }

        var summary = BatchOperationSummary()
        for path in uniquePaths {
            do {
                _ = try await RustFFI.runWithTimeout(seconds: 12) {
                    try RustFFI.parseOKPayload(
                        RustFFI.call {
                            path.withCString { cPath in
                                orbit_sftp_remove_file(sid, cPath)
                            }
                        }
                    )
                }
                summary.succeeded.append(path)
            } catch {
                summary.failed[path] = error.localizedDescription
            }
        }

        do {
            try await refresh(path: currentPath)
        } catch {
            statusText = "批量删除后刷新失败: \(error.localizedDescription)"
        }

        if summary.hasFailure {
            statusText = "批量删除完成：成功 \(summary.successCount)，失败 \(summary.failureCount)"
        } else {
            statusText = "批量删除完成：共 \(summary.successCount) 项"
            successHaptic()
        }
        return summary
    }

}
