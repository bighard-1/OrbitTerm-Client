import Foundation

enum SFTPBatchOperationFormatter {
    static let noDownloadableFilesMessage = "未选择可下载文件（目录暂不支持批量下载）。"

    static func remotePaths(for items: [FileItem], currentPath: String) -> [String] {
        items.map { item in
            if currentPath == "/" {
                return "/\(item.name)"
            }
            return "\(currentPath)/\(item.name)"
        }
    }

    static func downloadableItems(from items: [FileItem]) -> [FileItem] {
        items.filter { !$0.isDirectory }
    }

    static func deleteResultMessage(for summary: BatchOperationSummary) -> String {
        if summary.hasFailure {
            return failureMessage(
                prefix: "成功 \(summary.successCount) 项，失败 \(summary.failureCount) 项。",
                failed: summary.failed
            )
        }
        return "已删除 \(summary.successCount) 项。"
    }

    static func downloadResultMessage(
        for summary: BatchOperationSummary, wasCancelled: Bool = false
    ) -> String {
        if wasCancelled {
            let cancelledCount = summary.cancellationCount
            let failures = summary.nonCancellationFailures
            if !summary.hasFailure {
                return "取消请求到达时下载已完成：共 \(summary.successCount) 项。已完成文件保留。"
            }
            let prefix = "批量下载已停止：成功 \(summary.successCount) 项，取消 \(cancelledCount) 项，失败 \(failures.count) 项。"
            if !failures.isEmpty {
                // Never let a list of ordinary cancellations hide a cleanup
                // failure or another actionable worker error.
                return failureMessage(prefix: prefix, failed: failures)
            }
            return prefix + "已完成文件保留。"
        }
        if summary.hasFailure {
            return failureMessage(
                prefix: "下载结束：成功 \(summary.successCount) 项，失败 \(summary.failureCount) 项。",
                failed: summary.failed
            )
        }
        return "下载完成：共 \(summary.successCount) 项。"
    }

    private static func failureMessage(prefix: String, failed: [String: String]) -> String {
        let topErrors = failed.sorted {
            let leftCleanup = $0.value.contains("目标清理失败")
            let rightCleanup = $1.value.contains("目标清理失败")
            if leftCleanup != rightCleanup { return leftCleanup }
            return $0.key < $1.key
        }.prefix(3)
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        let remaining = failed.count > 3 ? "\n另有 \(failed.count - 3) 项失败。" : ""
        return "\(prefix)\n\n\(topErrors)\(remaining)"
    }
}
