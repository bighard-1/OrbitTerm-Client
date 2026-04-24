import Foundation
import os
#if os(iOS)
import UIKit
#endif

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

enum SFTPError: LocalizedError {
    case notConnected
    case timeout
    case invalidResponse
    case rustError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "SFTP 未连接"
        case .timeout:
            return "网络连接超时，请检查 SSH 服务状态后重试"
        case .invalidResponse:
            return "Rust 返回了无效响应"
        case let .rustError(message):
            return message
        }
    }
}

@MainActor
final class SFTPManager: ObservableObject {
    @Published var items: [FileItem] = []
    @Published var currentPath: String = "/"
    @Published var isConnected: Bool = false
    @Published var isLoading: Bool = false
    @Published var statusText: String = "未连接"
    @Published var transfers: [TransferTaskItem] = []
    @Published var isUsingMockData: Bool = false

    private let logger = Logger(subsystem: "com.orbitterm.app", category: "sftp")
    private var sessionID: UInt64?

    var activeSessionID: UInt64? { sessionID }

    func activateMockIfNeeded(host: String, username: String, password: String) {
        guard host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              password.isEmpty,
              !isConnected else {
            return
        }

        useMockData(path: "/", status: "当前为模拟模式（未配置服务器）")
        isConnected = true
    }

    func connect(host: String, username: String, password: String, preferMock: Bool = false) async {
        let cleanedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        if preferMock || cleanedHost.isEmpty || cleanedUsername.isEmpty || password.isEmpty {
            useMockData(path: "/", status: "当前为模拟模式")
            isConnected = true
            debugLog("switch_to_mock", ["host": cleanedHost, "username": cleanedUsername])
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let sessionPayload = try await runBlockingWithTimeout(seconds: 12) {
                try Self.parseOKPayload(
                    Self.callRust {
                        cleanedHost.withCString { h in
                            cleanedUsername.withCString { u in
                                password.withCString { p in
                                    orbit_sftp_connect(h, u, p)
                                }
                            }
                        }
                    }
                )
            }

            guard let sid = UInt64(sessionPayload) else {
                throw SFTPError.invalidResponse
            }

            sessionID = sid
            isUsingMockData = false
            isConnected = true
            statusText = "已连接"
            debugLog("connect_ok", ["session": "\(sid)"])
            try await refresh(path: "/")
            successHaptic()
        } catch {
            statusText = "连接失败: \(error.localizedDescription)"
            isConnected = false
            sessionID = nil
            debugLog("connect_failed", ["error": error.localizedDescription])
        }
    }

    func disconnect() async {
        if isUsingMockData {
            items = []
            isConnected = false
            currentPath = "/"
            statusText = "已断开"
            return
        }

        guard let sid = sessionID else { return }
        _ = try? await runBlockingWithTimeout(seconds: 8) {
            try Self.parseOKPayload(Self.callRust { orbit_sftp_disconnect(sid) })
        }
        isConnected = false
        sessionID = nil
        items = []
        currentPath = "/"
        statusText = "已断开"
    }

    func refresh(path: String? = nil) async throws {
        let targetPath = path ?? currentPath

        if isUsingMockData {
            useMockData(path: targetPath, status: "模拟目录：\(targetPath)")
            return
        }

        guard let sid = sessionID else { throw SFTPError.notConnected }

        isLoading = true
        defer { isLoading = false }

        let payload = try await runBlockingWithTimeout(seconds: 10) {
            try Self.parseOKPayload(
                Self.callRust {
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

    func goToPath(_ path: String) async {
        do {
            try await refresh(path: path)
        } catch {
            statusText = "路径跳转失败: \(error.localizedDescription)"
        }
    }

    func upload(localURL: URL, remotePath: String? = nil, progress: ((Double) -> Void)? = nil) async {
        if isUsingMockData {
            statusText = "模拟模式下不可上传"
            return
        }
        guard let sid = sessionID else {
            statusText = "上传失败: 未连接"
            return
        }

        let task = TransferTaskItem(
            fileName: localURL.lastPathComponent,
            direction: .upload,
            progress: 0,
            statusText: "准备上传",
            isDone: false
        )
        transfers.insert(task, at: 0)
        progress?(0)

        let remoteTarget = remotePath ?? makeChildPath(name: localURL.lastPathComponent)
        debugLog("upload_start", [
            "session": "\(sid)",
            "local": localURL.path,
            "remote": remoteTarget
        ])

        do {
            let payload = try await runBlockingWithTimeout(seconds: 45) {
                try Self.parseOKPayload(
                    Self.callRust {
                        localURL.path.withCString { local in
                            remoteTarget.withCString { remote in
                                orbit_sftp_upload_file(sid, local, remote)
                            }
                        }
                    }
                )
            }

            let bytes = parseTransferBytes(payload)
            updateTransfer(taskID: task.id, progress: 1, statusText: "上传完成 \(FileSizeFormatter.humanReadable(bytes))", isDone: true)
            progress?(1)
            try await refresh(path: currentPath)
            successHaptic()
            debugLog("upload_ok", ["bytes": "\(bytes)"])
        } catch {
            updateTransfer(taskID: task.id, progress: 0, statusText: "上传失败: \(error.localizedDescription)", isDone: true)
            statusText = "上传失败: \(error.localizedDescription)"
            debugLog("upload_failed", ["error": error.localizedDescription])
        }
    }

    func download(item: FileItem, to localURL: URL, resumeOffset: UInt64 = 0, progress: ((Double) -> Void)? = nil) async {
        if isUsingMockData {
            statusText = "模拟模式下不可下载"
            return
        }
        guard let sid = sessionID else {
            statusText = "下载失败: 未连接"
            return
        }

        let remotePath = makeChildPath(name: item.name)
        let task = TransferTaskItem(
            fileName: item.name,
            direction: .download,
            progress: 0,
            statusText: "准备下载",
            isDone: false
        )
        transfers.insert(task, at: 0)
        progress?(0)

        debugLog("download_start", [
            "session": "\(sid)",
            "remote": remotePath,
            "local": localURL.path,
            "resume": "\(resumeOffset)"
        ])

        do {
            let payload = try await runBlockingWithTimeout(seconds: 45) {
                try Self.parseOKPayload(
                    Self.callRust {
                        remotePath.withCString { remote in
                            localURL.path.withCString { local in
                                orbit_sftp_download_file(sid, remote, local, resumeOffset)
                            }
                        }
                    }
                )
            }

            let bytes = parseTransferBytes(payload)
            updateTransfer(taskID: task.id, progress: 1, statusText: "下载完成 \(FileSizeFormatter.humanReadable(bytes))", isDone: true)
            progress?(1)
            successHaptic()
            debugLog("download_ok", ["bytes": "\(bytes)"])
        } catch {
            updateTransfer(taskID: task.id, progress: 0, statusText: "下载失败: \(error.localizedDescription)", isDone: true)
            statusText = "下载失败: \(error.localizedDescription)"
            debugLog("download_failed", ["error": error.localizedDescription])
        }
    }

    func delete(item: FileItem) async {
        if isUsingMockData {
            items.removeAll { $0.id == item.id }
            statusText = "模拟模式：已删除 \(item.name)"
            successHaptic()
            return
        }
        guard let sid = sessionID else {
            statusText = "删除失败: 未连接"
            return
        }

        let remotePath = makeChildPath(name: item.name)
        do {
            _ = try await runBlockingWithTimeout(seconds: 10) {
                try Self.parseOKPayload(
                    Self.callRust {
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

        guard let sid = sessionID else {
            statusText = "重命名失败: 未连接"
            return
        }

        let oldPath = makeChildPath(name: item.name)
        let newPath = makeChildPath(name: cleaned)

        do {
            _ = try await runBlockingWithTimeout(seconds: 10) {
                try Self.parseOKPayload(
                    Self.callRust {
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

    func makeChildPath(name: String) -> String {
        if currentPath == "/" {
            return "/\(name)"
        }
        return currentPath + "/" + name
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

    private func runBlockingWithTimeout<T>(seconds: TimeInterval, _ work: @escaping () throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(priority: .userInitiated) {
                try work()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SFTPError.timeout
            }

            guard let first = try await group.next() else {
                throw SFTPError.invalidResponse
            }
            group.cancelAll()
            return first
        }
    }

    private func useMockData(path: String, status: String) {
        isUsingMockData = true
        currentPath = path
        items = Self.mockItems(path: path)
        statusText = status
        debugLog("mock_items", ["path": path, "count": "\(items.count)"])
    }

    private func debugLog(_ event: String, _ fields: [String: String]) {
        let text = fields
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
        logger.debug("[SFTP] \(event, privacy: .public) \(text, privacy: .public)")
    }

    private nonisolated static func callRust(_ call: () -> UnsafeMutablePointer<CChar>?) -> String {
        guard let ptr = call() else {
            return "ERR:Rust 返回空指针"
        }

        defer { orbit_free_string(ptr) }
        return String(cString: ptr)
    }

    private nonisolated static func parseOKPayload(_ raw: String) throws -> String {
        if raw.hasPrefix("OK:") {
            return String(raw.dropFirst(3))
        }
        if raw.hasPrefix("ERR:") {
            throw SFTPError.rustError(String(raw.dropFirst(4)))
        }
        throw SFTPError.invalidResponse
    }

    private static func mockItems(path: String) -> [FileItem] {
        let now = UInt64(Date().timeIntervalSince1970)
        switch path {
        case "/":
            return [
                FileItem(name: "var", size: 0, permissions: "drwxr-xr-x", permissionsOctal: 0o040755, modifiedAtUnix: now - 3600),
                FileItem(name: "home", size: 0, permissions: "drwxr-xr-x", permissionsOctal: 0o040755, modifiedAtUnix: now - 7200),
                FileItem(name: "readme.txt", size: 1_280, permissions: "-rw-r--r--", permissionsOctal: 0o100644, modifiedAtUnix: now - 90)
            ]
        case "/var":
            return [
                FileItem(name: "www", size: 0, permissions: "drwxr-xr-x", permissionsOctal: 0o040755, modifiedAtUnix: now - 200),
                FileItem(name: "log", size: 0, permissions: "drwxr-x---", permissionsOctal: 0o040750, modifiedAtUnix: now - 400)
            ]
        case "/var/www":
            return [
                FileItem(name: "index.html", size: 8_920, permissions: "-rw-r--r--", permissionsOctal: 0o100644, modifiedAtUnix: now - 20),
                FileItem(name: "assets", size: 0, permissions: "drwxr-xr-x", permissionsOctal: 0o040755, modifiedAtUnix: now - 360)
            ]
        default:
            return []
        }
    }

    private func successHaptic() {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
        #endif
    }
}
