import Foundation

private let sftpInAppTextMaximumBytes: UInt64 = 2 * 1024 * 1024

private struct SFTPCheckedEnvelope<Payload: Decodable>: Decodable {
    let schemaVersion: UInt32
    let requestID: String?
    let kind: String
    let data: Payload?
    let error: SFTPCheckedErrorPayload?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case kind, data, error
    }
}

private struct SFTPCheckedErrorPayload: Decodable {
    let code: String
}

private struct SFTPCheckedTextPayload: Decodable {
    let sftpSessionID: String
    let path: String
    let securityGeneration: String
    let byteLength: UInt64
    let content: String

    private enum CodingKeys: String, CodingKey {
        case sftpSessionID = "sftp_session_id"
        case path
        case securityGeneration = "security_generation"
        case byteLength = "byte_length"
        case content
    }
}

private struct SFTPCheckedMutationPayload: Decodable {
    let sftpSessionID: String
    let operation: String
    let path: String
    let securityGeneration: String

    private enum CodingKeys: String, CodingKey {
        case sftpSessionID = "sftp_session_id"
        case operation, path
        case securityGeneration = "security_generation"
    }
}

private final class SFTPRecursiveDeleteBudget {
    var remainingEntries: Int

    init(remainingEntries: Int) {
        self.remainingEntries = remainingEntries
    }
}

extension SFTPManager {
    private static let maximumRecursiveDeleteDepth = 48
    private static let maximumRecursiveDeleteEntries = 10_000

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
            if isCheckedConnection {
                try await createCheckedEntry(path: path, operation: "mkdir") { sessionID, pathPointer, requestPointer in
                    orbit_sftp_mkdir_checked_v1(sessionID, pathPointer, requestPointer)
                }
                try await refresh(path: currentPath)
                statusText = "目录已创建"
                successHaptic()
                return
            }
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
            if isCheckedConnection {
                try await createCheckedEntry(path: path, operation: "create_file") { sessionID, pathPointer, requestPointer in
                    orbit_sftp_create_file_checked_v1(sessionID, pathPointer, requestPointer)
                }
                try await refresh(path: currentPath)
                statusText = "文件已创建"
                successHaptic()
                return
            }
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
            throw SFTPError.rustError("目录不支持应用内打开")
        }
        guard item.size <= sftpInAppTextMaximumBytes else {
            throw SFTPError.rustError("文件超过 2 MB，请下载后处理")
        }
        guard let sid = operationSessionID else {
            throw SFTPError.notConnected
        }
        let path = makeChildPath(name: item.name)
        if isCheckedConnection {
            let requestID = UUID().uuidString.lowercased()
            let raw = try await RustFFI.runWithTimeout(seconds: 12) {
                RustFFI.call {
                    path.withCString { pathPointer in
                        requestID.withCString { requestPointer in
                            orbit_sftp_read_text_checked_v1(sid, pathPointer, requestPointer)
                        }
                    }
                }
            }
            let payload: SFTPCheckedTextPayload = try decodeCheckedSFTPResponse(
                raw,
                requestID: requestID,
                expectedKind: "sftp_text_file"
            )
            guard payload.sftpSessionID == String(sid),
                  payload.path == path,
                  payload.securityGeneration == "host_key_verified",
                  payload.byteLength == UInt64(payload.content.utf8.count),
                  payload.byteLength <= sftpInAppTextMaximumBytes else {
                throw SFTPError.invalidResponse
            }
            return payload.content
        }
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
        let contentBytes = Array(content.utf8)
        guard UInt64(contentBytes.count) <= sftpInAppTextMaximumBytes else {
            throw SFTPError.rustError("编辑内容超过 2 MB，未保存")
        }
        let path = makeChildPath(name: item.name)
        if isCheckedConnection {
            let requestID = UUID().uuidString.lowercased()
            let raw = try await RustFFI.runWithTimeout(seconds: 15) {
                RustFFI.call {
                    contentBytes.withUnsafeBytes { contentBuffer in
                        path.withCString { pathPointer in
                            requestID.withCString { requestPointer in
                                orbit_sftp_write_text_checked_v1(
                                    sid,
                                    pathPointer,
                                    contentBuffer.bindMemory(to: UInt8.self).baseAddress,
                                    contentBuffer.count,
                                    item.size,
                                    item.permissionsOctal,
                                    item.modifiedAtUnix,
                                    item.isDirectory ? 1 : 0,
                                    requestPointer
                                )
                            }
                        }
                    }
                }
            }
            let payload: SFTPCheckedMutationPayload = try decodeCheckedSFTPResponse(
                raw,
                requestID: requestID,
                expectedKind: "sftp_mutation_completed"
            )
            guard payload.sftpSessionID == String(sid),
                  payload.operation == "write_text",
                  payload.path == path,
                  payload.securityGeneration == "host_key_verified" else {
                throw SFTPError.invalidResponse
            }
            try await refresh(path: currentPath)
            statusText = "文件已保存"
            successHaptic()
            return
        }
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

    private func decodeCheckedSFTPResponse<Payload: Decodable>(
        _ raw: String,
        requestID: String,
        expectedKind: String
    ) throws -> Payload {
        guard let data = raw.data(using: .utf8) else { throw SFTPError.invalidResponse }
        let envelope = try JSONDecoder().decode(SFTPCheckedEnvelope<Payload>.self, from: data)
        guard envelope.schemaVersion == 1, envelope.requestID == requestID else {
            throw SFTPError.invalidResponse
        }
        if envelope.kind == "error" {
            throw SFTPError.rustError(checkedSFTPDocumentMessage(envelope.error?.code))
        }
        guard envelope.kind == expectedKind, envelope.error == nil, let payload = envelope.data else {
            throw SFTPError.invalidResponse
        }
        return payload
    }

    private func createCheckedEntry(
        path: String,
        operation: String,
        call: @escaping (
            UInt64,
            UnsafePointer<CChar>,
            UnsafePointer<CChar>
        ) -> UnsafeMutablePointer<CChar>?
    ) async throws {
        guard let sid = checkedSessionID?.ffiValue else { throw SFTPError.notConnected }
        let requestID = UUID().uuidString.lowercased()
        let raw = try await RustFFI.runWithTimeout(seconds: 10) {
            RustFFI.call {
                path.withCString { pathPointer in
                    requestID.withCString { requestPointer in
                        call(sid, pathPointer, requestPointer)
                    }
                }
            }
        }
        let payload: SFTPCheckedMutationPayload = try decodeCheckedSFTPResponse(
            raw,
            requestID: requestID,
            expectedKind: "sftp_mutation_completed"
        )
        guard payload.sftpSessionID == String(sid),
              payload.operation == operation,
              payload.path == path,
              payload.securityGeneration == "host_key_verified" else {
            throw SFTPError.invalidResponse
        }
    }

    private func checkedSFTPDocumentMessage(_ code: String?) -> String {
        switch code {
        case "sftp_permission_denied":
            return "当前目录不可写，请进入用户主目录或选择有写入权限的目录"
        case "sftp_target_exists":
            return "同名文件或目录已存在"
        case "sftp_entry_changed":
            return "远端文件已被修改，未覆盖保存；当前草稿仍已保留"
        case "security_generation_mismatch", "legacy_session_not_allowed":
            return "当前 SFTP 会话的安全状态已变化，请重新连接后重试"
        case "sftp_read_failed":
            return "无法作为 UTF-8 文本打开，或当前账户无读取权限"
        case "sftp_write_failed":
            return "保存失败，请检查远端文件权限后重试"
        case "invalid_request":
            return "文件路径或编辑内容无效"
        default:
            return "SFTP 文件操作失败，请重新连接后重试"
        }
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
            if item.isDirectory {
                statusText = "正在删除目录及其内容…"
                let budget = SFTPRecursiveDeleteBudget(
                    remainingEntries: Self.maximumRecursiveDeleteEntries
                )
                try await deleteDirectoryTree(
                    at: remotePath,
                    sessionID: sid,
                    depth: 0,
                    budget: budget
                )
            } else {
                try await removeRemoteEntry(at: remotePath, sessionID: sid)
            }
            try await refresh(path: currentPath)
            statusText = item.isDirectory ? "目录及其内容已删除" : "文件已删除"
            successHaptic()
        } catch {
            statusText = "删除失败: \(error.localizedDescription)"
        }
    }

    private func deleteDirectoryTree(
        at directoryPath: String,
        sessionID: UInt64,
        depth: Int,
        budget: SFTPRecursiveDeleteBudget
    ) async throws {
        guard depth < Self.maximumRecursiveDeleteDepth else {
            throw SFTPError.rustError("目录层级超过安全删除上限")
        }

        let children = try await directoryItems(at: directoryPath, sessionID: sessionID)
        for child in children {
            guard let childPath = safeChildPath(parent: directoryPath, name: child.name) else {
                throw SFTPError.rustError("远程目录包含不安全名称，已停止删除")
            }
            guard budget.remainingEntries > 0 else {
                throw SFTPError.rustError("目录项目超过安全删除上限")
            }
            budget.remainingEntries -= 1

            if child.isDirectory {
                try await deleteDirectoryTree(
                    at: childPath,
                    sessionID: sessionID,
                    depth: depth + 1,
                    budget: budget
                )
            } else {
                try await removeRemoteEntry(at: childPath, sessionID: sessionID)
            }
        }
        try await removeRemoteEntry(at: directoryPath, sessionID: sessionID)
    }

    private func removeRemoteEntry(at path: String, sessionID: UInt64) async throws {
        _ = try await RustFFI.runWithTimeout(seconds: 12) {
            try RustFFI.parseOKPayload(
                RustFFI.call {
                    path.withCString { cPath in
                        orbit_sftp_remove_file(sessionID, cPath)
                    }
                }
            )
        }
    }

    private func safeChildPath(parent: String, name: String) -> String? {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.utf8.contains(0) else {
            return nil
        }
        return parent == "/" ? "/\(name)" : "\(parent)/\(name)"
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
