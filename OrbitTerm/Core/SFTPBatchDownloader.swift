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
    nonisolated static func run(
        sessionID: UInt64,
        entries: [SFTPBatchDownloadEntry],
        maxConcurrent: Int
    ) async -> [SFTPBatchDownloadSingleResult] {
        var results: [SFTPBatchDownloadSingleResult] = []
        results.reserveCapacity(entries.count)

        var iterator = entries.makeIterator()
        let workerCount = max(1, min(maxConcurrent, entries.count))
        await withTaskGroup(of: SFTPBatchDownloadSingleResult.self) { group in
            for _ in 0..<workerCount {
                guard let next = iterator.next() else { break }
                group.addTask {
                    await downloadEntry(sessionID: sessionID, entry: next)
                }
            }

            while let result = await group.next() {
                results.append(result)
                if let next = iterator.next() {
                    group.addTask {
                        await downloadEntry(sessionID: sessionID, entry: next)
                    }
                }
            }
        }

        return results
    }

    private nonisolated static func downloadEntry(
        sessionID: UInt64,
        entry: SFTPBatchDownloadEntry
    ) async -> SFTPBatchDownloadSingleResult {
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

            struct TransferResp: Decodable { let bytes: UInt64 }
            let bytes = (try? JSONDecoder().decode(TransferResp.self, from: Data(payload.utf8)).bytes) ?? 0

            return SFTPBatchDownloadSingleResult(
                fileName: entry.item.name,
                localURL: entry.localURL,
                bytes: bytes,
                error: nil
            )
        } catch {
            return SFTPBatchDownloadSingleResult(
                fileName: entry.item.name,
                localURL: entry.localURL,
                bytes: nil,
                error: error.localizedDescription
            )
        }
    }
}
