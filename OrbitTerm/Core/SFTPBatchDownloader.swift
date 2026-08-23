import Foundation

struct SFTPBatchDownloadEntry: Sendable {
    let item: FileItem
    let remotePath: String
    let localURL: URL
}

struct SFTPBatchDownloadSingleResult: Sendable {
    let fileName: String
    let localURL: URL
    let bytes: UInt64?
    let error: String?
}

enum SFTPBatchDownloader {
    /// Shared resource budget for file transfers. A caller may request fewer
    /// workers, but never more than this many concurrent Rust/SSH operations.
    static let maximumConcurrentTransfers = OperationResourceBudget.sftpMaximumConcurrentTransfers
    private static let cancelledMessage = "传输已取消"

    nonisolated static func run(
        sessionID: UInt64,
        entries: [SFTPBatchDownloadEntry],
        maxConcurrent: Int
    ) async -> [SFTPBatchDownloadSingleResult] {
        var results: [SFTPBatchDownloadSingleResult] = []
        results.reserveCapacity(entries.count)

        var nextIndex = 0
        let workerCount = OperationConcurrencyPolicy.workerCount(
            requested: maxConcurrent,
            itemCount: entries.count,
            maximum: maximumConcurrentTransfers
        )
        await withTaskGroup(of: SFTPBatchDownloadSingleResult.self) { group in
            for _ in 0..<workerCount {
                guard nextIndex < entries.count else { break }
                let next = entries[nextIndex]
                nextIndex += 1
                group.addTask {
                    await downloadEntry(sessionID: sessionID, entry: next)
                }
            }

            while let result = await group.next() {
                results.append(result)
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                if nextIndex < entries.count {
                    let next = entries[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        await downloadEntry(sessionID: sessionID, entry: next)
                    }
                }
            }

            if Task.isCancelled {
                // Mark entries never handed to a worker so the caller can
                // render a complete, deterministic batch result.
                for entry in entries[nextIndex...] {
                    results.append(cancelledResult(for: entry))
                }
                while let result = await group.next() {
                    results.append(result)
                }
            }
        }

        return results
    }

    private nonisolated static func downloadEntry(
        sessionID: UInt64,
        entry: SFTPBatchDownloadEntry
    ) async -> SFTPBatchDownloadSingleResult {
        guard !Task.isCancelled else { return cancelledResult(for: entry) }
        if entry.item.isDirectory {
            return SFTPBatchDownloadSingleResult(
                fileName: entry.item.name,
                localURL: entry.localURL,
                bytes: nil,
                error: "目录暂不支持批量下载"
            )
        }

        do {
            let payload = try await RustFFI.runWithTimeout(seconds: 50) {
                try RustFFI.parseOKPayload(
                    RustFFI.call {
                        entry.remotePath.withCString { remote in
                            entry.localURL.path.withCString { local in
                                orbit_sftp_download_file(sessionID, remote, local, 0)
                            }
                        }
                    }
                )
            }

            guard !Task.isCancelled else { return cancelledResult(for: entry) }

            struct TransferResp: Decodable { let bytes: UInt64 }
            let bytes = (try? JSONDecoder().decode(TransferResp.self, from: Data(payload.utf8)).bytes) ?? 0

            return SFTPBatchDownloadSingleResult(
                fileName: entry.item.name,
                localURL: entry.localURL,
                bytes: bytes,
                error: nil
            )
        } catch {
            if Task.isCancelled {
                return cancelledResult(for: entry)
            }
            return SFTPBatchDownloadSingleResult(
                fileName: entry.item.name,
                localURL: entry.localURL,
                bytes: nil,
                error: error.localizedDescription
            )
        }
    }

    private nonisolated static func cancelledResult(
        for entry: SFTPBatchDownloadEntry
    ) -> SFTPBatchDownloadSingleResult {
        SFTPBatchDownloadSingleResult(
            fileName: entry.item.name,
            localURL: entry.localURL,
            bytes: nil,
            error: cancelledMessage
        )
    }
}
