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
    @Published var checkedConnection: CheckedSFTPConnection?
    @Published var checkedError: CheckedSFTPServiceError?
    private(set) var connectionMode: ConnectionSecurityPolicy = .applicationDefault

    private let logger = Logger(subsystem: "com.orbitterm.app", category: "sftp")
    var sessionID: UInt64?

    var activeSessionID: UInt64? { operationSessionID }
    var checkedSessionID: SFTPSessionID? { checkedConnection?.sftpSessionID }
    var isCheckedConnection: Bool { checkedConnection != nil }

    // Existing SFTP ABIs still accept UInt64. This is the only typed checked-ID conversion boundary.
    var operationSessionID: UInt64? {
        checkedConnection?.sftpSessionID.ffiValue ?? sessionID
    }

    func makeChildPath(name: String) -> String {
        if currentPath == "/" {
            return "/\(name)"
        }
        return currentPath + "/" + name
    }

    func useMockData(path: String, status: String) {
        checkedConnection = nil
        checkedError = nil
        isUsingMockData = true
        currentPath = path
        items = Self.mockItems(path: path)
        statusText = status
        debugLog("mock_items", ["path": path, "count": "\(items.count)"])
    }

    func rejectCheckedStandalone(_ error: CheckedSFTPServiceError = .requiresVerifiedSession) {
        checkedConnection = nil
        checkedError = error
        sessionID = nil
        isConnected = false
        isUsingMockData = false
        statusText = error.userMessage
    }

    func configureConnectionMode(_ mode: ConnectionSecurityPolicy) {
        connectionMode = mode
    }

    var allowsLegacyConnection: Bool { connectionMode.allowsLegacyNetwork }

    func debugLog(_ event: String, _ fields: [String: String]) {
        let text = fields
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
        logger.debug("[SFTP] \(event, privacy: .public) \(text, privacy: .public)")
    }
}
