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

    static func downloadResultMessage(for summary: BatchOperationSummary) -> String {
        if summary.hasFailure {
            return failureMessage(
                prefix: "下载完成：成功 \(summary.successCount) 项，失败 \(summary.failureCount) 项。",
                failed: summary.failed
            )
        }
        return "下载完成：共 \(summary.successCount) 项。"
    }

    private static func failureMessage(prefix: String, failed: [String: String]) -> String {
        let topErrors = failed.prefix(3)
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        return "\(prefix)\n\n\(topErrors)"
    }
}
