import Foundation

struct FileItem: Identifiable, Hashable, Decodable {
    let name: String
    let size: UInt64
    let permissions: String
    let permissionsOctal: UInt32
    let modifiedAtUnix: UInt64

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case permissions
        case permissionsOctal = "permissions_octal"
        case modifiedAtUnix = "modified_at_unix"
    }

    var id: String { name }

    var isDirectory: Bool {
        (permissionsOctal & 0o040000) != 0 || permissions.hasPrefix("d")
    }

    var iconName: String {
        if isDirectory { return "folder.fill" }
        let ext = (name as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg"].contains(ext) {
            return "photo"
        }
        if ["zip", "rar", "7z", "tar", "gz"].contains(ext) {
            return "archivebox.fill"
        }
        if ["swift", "go", "rs", "py", "js", "ts", "json", "yaml", "yml", "md", "txt", "log"].contains(ext) {
            return "doc.plaintext.fill"
        }
        return "doc.fill"
    }

    var formattedSize: String {
        FileSizeFormatter.humanReadable(size)
    }

    var formattedDate: String {
        let date = Date(timeIntervalSince1970: TimeInterval(modifiedAtUnix))
        return FileItem.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

enum TransferDirection: String {
    case upload = "上传"
    case download = "下载"
}

struct TransferTaskItem: Identifiable {
    let id = UUID()
    let fileName: String
    let direction: TransferDirection
    var progress: Double
    var statusText: String
    var isDone: Bool
}

struct BatchOperationSummary {
    var succeeded: [String] = []
    var failed: [String: String] = [:]

    var successCount: Int { succeeded.count }
    var failureCount: Int { failed.count }
    var hasFailure: Bool { !failed.isEmpty }
}

struct BatchDownloadProgress {
    let completed: Int
    let total: Int
    let bytesTransferred: UInt64
    let currentFile: String

    var fraction: Double {
        guard total > 0 else { return 1 }
        return Double(completed) / Double(total)
    }
}

struct BatchDownloadResult {
    var summary: BatchOperationSummary
    var downloadedURLs: [URL]
}
