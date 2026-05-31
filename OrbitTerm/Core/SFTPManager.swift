import Foundation
import os

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
    var sessionID: UInt64?

    var activeSessionID: UInt64? { sessionID }

    func makeChildPath(name: String) -> String {
        if currentPath == "/" {
            return "/\(name)"
        }
        return currentPath + "/" + name
    }

    func useMockData(path: String, status: String) {
        isUsingMockData = true
        currentPath = path
        items = Self.mockItems(path: path)
        statusText = status
        debugLog("mock_items", ["path": path, "count": "\(items.count)"])
    }

    func debugLog(_ event: String, _ fields: [String: String]) {
        let text = fields
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
        logger.debug("[SFTP] \(event, privacy: .public) \(text, privacy: .public)")
    }
}
