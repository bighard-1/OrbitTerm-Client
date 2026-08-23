import Foundation

extension SFTPManager {
    func upload(localURL: URL, remotePath: String? = nil, progress: ((Double) -> Void)? = nil) async {
        if isUsingMockData {
            statusText = "模拟模式下不可上传"
            return
        }
        guard let sid = operationSessionID else {
            statusText = "上传失败: 未连接"
            return
        }
        guard let connectionLease = currentTransferConnectionLease(sessionID: sid) else {
            return
        }

        guard beginTransferOperation() != nil else { return }
        defer { finishTransferOperation() }

        let task = TransferTaskItem(
            fileName: localURL.lastPathComponent,
            direction: .upload,
            progress: 0,
            statusText: "准备上传",
            isDone: false
        )
        recordTransfer(task)
        registerTransferRetry(taskID: task.id) { [weak self] in
            guard let self else { return }
            Task { await self.upload(localURL: localURL, remotePath: remotePath, progress: nil) }
        }
        progress?(0)

        let remoteTarget = remotePath ?? makeChildPath(name: localURL.lastPathComponent)
        debugLog("upload_start", [
            "session": "\(sid)",
            "local": localURL.path,
            "remote": remoteTarget
        ])

        do {
            let payload = try await RustFFI.runWithTimeout(seconds: 45) {
                try RustFFI.parseOKPayload(
                    RustFFI.call {
                        localURL.path.withCString { local in
                            remoteTarget.withCString { remote in
                                orbit_sftp_upload_file(sid, local, remote)
                            }
                        }
                    }
                )
            }

            let bytes = parseTransferBytes(payload)
            guard acceptsTransferCompletion(connectionLease, sessionID: sid) else { return }
            updateTransfer(taskID: task.id, progress: 1, statusText: "上传完成 \(FileSizeFormatter.humanReadable(bytes))", isDone: true)
            trimTransferHistory()
            progress?(1)
            try await refresh(path: currentPath)
            successHaptic()
            debugLog("upload_ok", ["bytes": "\(bytes)"])
        } catch {
            guard acceptsTransferCompletion(connectionLease, sessionID: sid) else { return }
            updateTransfer(taskID: task.id, progress: 0, statusText: "上传失败: \(error.localizedDescription)", isDone: true)
            trimTransferHistory()
            statusText = "上传失败: \(error.localizedDescription)"
            debugLog("upload_failed", ["error": error.localizedDescription])
        }
    }

    func download(item: FileItem, to localURL: URL, resumeOffset: UInt64 = 0, progress: ((Double) -> Void)? = nil) async {
        if isUsingMockData {
            statusText = "模拟模式下不可下载"
            return
        }
        guard let sid = operationSessionID else {
            statusText = "下载失败: 未连接"
            return
        }
        guard let connectionLease = currentTransferConnectionLease(sessionID: sid) else {
            return
        }

        let remotePath = makeChildPath(name: item.name)
        guard beginTransferOperation() != nil else { return }
        defer { finishTransferOperation() }

        let task = TransferTaskItem(
            fileName: item.name,
            direction: .download,
            progress: 0,
            statusText: "准备下载",
            isDone: false
        )
        recordTransfer(task)
        registerTransferRetry(taskID: task.id) { [weak self] in
            guard let self else { return }
            Task { await self.download(item: item, to: localURL, resumeOffset: resumeOffset, progress: nil) }
        }
        progress?(0)

        debugLog("download_start", [
            "session": "\(sid)",
            "remote": remotePath,
            "local": localURL.path,
            "resume": "\(resumeOffset)"
        ])

        do {
            let payload = try await RustFFI.runWithTimeout(seconds: 45) {
                try RustFFI.parseOKPayload(
                    RustFFI.call {
                        remotePath.withCString { remote in
                            localURL.path.withCString { local in
                                orbit_sftp_download_file(sid, remote, local, resumeOffset)
                            }
                        }
                    }
                )
            }

            let bytes = parseTransferBytes(payload)
            guard acceptsTransferCompletion(connectionLease, sessionID: sid) else { return }
            updateTransfer(taskID: task.id, progress: 1, statusText: "下载完成 \(FileSizeFormatter.humanReadable(bytes))", isDone: true)
            trimTransferHistory()
            progress?(1)
            successHaptic()
            debugLog("download_ok", ["bytes": "\(bytes)"])
        } catch {
            guard acceptsTransferCompletion(connectionLease, sessionID: sid) else { return }
            updateTransfer(taskID: task.id, progress: 0, statusText: "下载失败: \(error.localizedDescription)", isDone: true)
            trimTransferHistory()
            statusText = "下载失败: \(error.localizedDescription)"
            debugLog("download_failed", ["error": error.localizedDescription])
        }
    }

    func batchDownload(
        items: [FileItem],
        destinationDirectory: URL,
        maxConcurrent: Int = OperationResourceBudget.sftpMaximumConcurrentTransfers,
        progress: (@Sendable (BatchDownloadProgress) -> Void)? = nil
    ) async -> BatchDownloadResult {
        let total = items.count
        guard total > 0 else {
            return BatchDownloadResult(summary: BatchOperationSummary(), downloadedURLs: [])
        }
        guard let sid = operationSessionID else {
            let failed = Dictionary(uniqueKeysWithValues: items.map { ($0.name, "未连接") })
            return BatchDownloadResult(summary: BatchOperationSummary(succeeded: [], failed: failed), downloadedURLs: [])
        }
        guard let connectionLease = currentTransferConnectionLease(sessionID: sid) else {
            let failed = Dictionary(uniqueKeysWithValues: items.map { ($0.name, "会话已切换或断开") })
            return BatchDownloadResult(summary: BatchOperationSummary(succeeded: [], failed: failed), downloadedURLs: [])
        }

        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            let failed = Dictionary(uniqueKeysWithValues: items.map { ($0.name, "创建目录失败: \(error.localizedDescription)") })
            return BatchDownloadResult(summary: BatchOperationSummary(succeeded: [], failed: failed), downloadedURLs: [])
        }

        let entries: [SFTPBatchDownloadEntry] = items.map { item in
            SFTPBatchDownloadEntry(
                item: item,
                remotePath: makeChildPath(name: item.name),
                localURL: destinationDirectory.appendingPathComponent(item.name)
            )
        }

        guard let grantedWorkers = beginTransferOperation(requestedSlots: maxConcurrent) else {
            let failed = Dictionary(uniqueKeysWithValues: items.map { ($0.name, "传输队列繁忙") })
            return BatchDownloadResult(summary: BatchOperationSummary(succeeded: [], failed: failed), downloadedURLs: [])
        }
        defer { finishTransferOperation(slots: grantedWorkers) }

        let results = await SFTPBatchDownloader.run(
            sessionID: sid,
            entries: entries,
            maxConcurrent: grantedWorkers
        )

        guard acceptsTransferCompletion(connectionLease, sessionID: sid) else {
            let failed = Dictionary(uniqueKeysWithValues: items.map { ($0.name, "会话已切换或断开") })
            return BatchDownloadResult(summary: BatchOperationSummary(succeeded: [], failed: failed), downloadedURLs: [])
        }

        var summary = BatchOperationSummary()
        var urls: [URL] = []
        var transferredBytes: UInt64 = 0
        var completed = 0

        for result in results {
            completed += 1
            if let err = result.error {
                summary.failed[result.fileName] = err
            } else {
                summary.succeeded.append(result.fileName)
                urls.append(result.localURL)
                transferredBytes += result.bytes ?? 0
            }
            progress?(BatchDownloadProgress(
                completed: completed,
                total: total,
                bytesTransferred: transferredBytes,
                currentFile: result.fileName
            ))
        }

        if summary.hasFailure {
            statusText = "批量下载完成：成功 \(summary.successCount)，失败 \(summary.failureCount)"
        } else {
            statusText = "批量下载完成：\(summary.successCount) 项"
            successHaptic()
        }

        return BatchDownloadResult(summary: summary, downloadedURLs: urls)
    }

    private func parseTransferBytes(_ payload: String) -> UInt64 {
        struct TransferResp: Decodable { let bytes: UInt64 }
        guard let data = payload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(TransferResp.self, from: data) else {
            return 0
        }
        return decoded.bytes
    }

    private func updateTransfer(taskID: UUID, progress: Double, statusText: String, isDone: Bool) {
        guard let index = transfers.firstIndex(where: { $0.id == taskID }) else { return }
        transfers[index].progress = progress
        transfers[index].statusText = statusText
        transfers[index].isDone = isDone
    }
}
