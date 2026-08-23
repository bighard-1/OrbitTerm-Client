import Foundation
import os

@MainActor
final class SFTPManager: ObservableObject {
    @Published var items: [FileItem] = []
    @Published var currentPath: String = "/"
    @Published var isConnected: Bool = false
    @Published var isLoading: Bool = false
    @Published var statusText: String = "未连接"
    /// A transient presentation hint created by explicit path navigation. It
    /// is local to one SFTP manager and never affects remote state, transfer
    /// selection, or connection ownership.
    @Published var highlightedItemID: FileItem.ID?
    @Published var transfers: [TransferTaskItem] = []
    @Published var isUsingMockData: Bool = false
    @Published var checkedConnection: CheckedSFTPConnection?
    @Published var checkedError: CheckedSFTPServiceError?
    private(set) var connectionMode: ConnectionSecurityPolicy = .applicationDefault
    private var directoryLoadOwner = OperationOwner()
    private var connectionOwner = OperationOwner()
    /// One connection-scoped lease is shared by concurrent transfers. Closing
    /// or replacing the SFTP channel invalidates it so an old completion can
    /// never publish into a newer directory/session.
    private var transferConnectionOwner = OperationOwner()
    private var transferConnectionLease: OperationLease?
    private var transferConcurrencyGate = OperationConcurrencyGate(
        maximumConcurrentOperations: OperationResourceBudget.sftpMaximumConcurrentTransfers
    )
    private var transferRetryActions: [UUID: @MainActor () -> Void] = [:]

    private let logger = Logger(subsystem: "com.orbitterm.app", category: "sftp")
    var sessionID: UInt64?

    var activeSessionID: UInt64? { operationSessionID }
    var checkedSessionID: SFTPSessionID? { checkedConnection?.sftpSessionID }
    var isCheckedConnection: Bool { checkedConnection != nil }
    var recoveryPresentation: OperationRecoveryPresentation? {
        checkedError.map(OperationRecoveryMapper.sftp)
    }

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
        #if !ORBITTERM_PUBLIC_RELEASE
        invalidateDirectoryLoads()
        invalidateTransferOperations()
        connectionOwner.invalidate()
        checkedConnection = nil
        checkedError = nil
        isUsingMockData = true
        currentPath = path
        items = Self.mockItems(path: path)
        highlightedItemID = nil
        statusText = status
        debugLog("mock_items", ["path": path, "count": "\(items.count)"])
        #else
        // A production build must never turn missing configuration into a
        // believable remote directory. Keep this defensive no-op in case a
        // future caller accidentally reaches the development-only API.
        invalidateDirectoryLoads()
        invalidateTransferOperations()
        connectionOwner.invalidate()
        checkedConnection = nil
        checkedError = nil
        isUsingMockData = false
        items = []
        highlightedItemID = nil
        statusText = "需要已配置的 SSH 会话"
        #endif
    }

    func rejectCheckedStandalone(_ error: CheckedSFTPServiceError = .requiresVerifiedSession) {
        invalidateDirectoryLoads()
        invalidateTransferOperations()
        connectionOwner.invalidate()
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
        logger.debug("[SFTP] event=\(event, privacy: .private(mask: .hash)) fields=\(text, privacy: .private(mask: .hash))")
    }

    /// Directory loads are presentation operations. A newer navigation or a
    /// disconnect invalidates an older load without changing the SFTP channel
    /// or any file-operation result.
    func beginDirectoryLoad() -> OperationLease {
        directoryLoadOwner.begin()
    }

    func isCurrentDirectoryLoad(_ lease: OperationLease, sessionID: UInt64) -> Bool {
        directoryLoadOwner.owns(lease) &&
            operationSessionID == sessionID &&
            isConnected &&
            !isUsingMockData
    }

    func finishDirectoryLoad(_ lease: OperationLease) {
        guard directoryLoadOwner.owns(lease) else { return }
        isLoading = false
    }

    func invalidateDirectoryLoads() {
        directoryLoadOwner.invalidate()
        isLoading = false
    }

    /// Admits a bounded number of file operations for one SFTP session. The
    /// caller owns the matching `finishTransferOperation()` call, including on
    /// cancellation or failure; this prevents drag-and-drop bursts from
    /// creating unbounded Rust/SSH work.
    func beginTransferOperation(requestedSlots: Int = 1) -> Int? {
        guard let granted = transferConcurrencyGate.acquire(requestedSlots: requestedSlots) else {
            statusText = "传输并发已达上限，请等待当前任务完成"
            return nil
        }
        return granted
    }

    func finishTransferOperation(slots: Int = 1) {
        transferConcurrencyGate.release(slots: slots)
    }

    func invalidateTransferOperations() {
        transferConnectionOwner.invalidate()
        transferConnectionLease = nil
        transferConcurrencyGate.reset()
        for index in transfers.indices where !transfers[index].isDone {
            transfers[index].statusText = "已取消（会话已切换或断开）"
            transfers[index].isDone = true
        }
        trimTransferHistory()
    }

    func establishTransferConnectionScope(sessionID: UInt64) {
        transferConnectionLease = transferConnectionOwner.begin(
            scope: .terminalChannel(sessionID)
        )
    }

    func beginConnectionOperation(scope: OperationScope) -> OperationLease {
        connectionOwner.begin(scope: scope)
    }

    func acceptsConnectionOperation(_ lease: OperationLease, scope: OperationScope) -> Bool {
        connectionOwner.owns(lease, scope: scope)
    }

    func invalidateConnectionOperations() {
        connectionOwner.invalidate()
    }

    func currentTransferConnectionLease(sessionID: UInt64) -> OperationLease? {
        guard let lease = transferConnectionLease,
              transferConnectionOwner.owns(lease, scope: .terminalChannel(sessionID)),
              operationSessionID == sessionID,
              isConnected,
              !isUsingMockData else {
            return nil
        }
        return lease
    }

    func acceptsTransferCompletion(_ lease: OperationLease, sessionID: UInt64) -> Bool {
        transferConnectionOwner.owns(lease, scope: .terminalChannel(sessionID)) &&
            operationSessionID == sessionID &&
            isConnected &&
            !isUsingMockData
    }

    func recordTransfer(_ task: TransferTaskItem) {
        transfers.insert(task, at: 0)
        trimTransferHistory()
    }

    func registerTransferRetry(taskID: UUID, action: @escaping @MainActor () -> Void) {
        transferRetryActions[taskID] = action
    }

    func retryTransfer(_ taskID: UUID) {
        guard let action = transferRetryActions[taskID] else { return }
        transfers.removeAll { $0.id == taskID }
        transferRetryActions.removeValue(forKey: taskID)
        action()
    }

    func clearCompletedTransfers() {
        let completedIDs = Set(transfers.filter(\.isDone).map(\.id))
        transfers.removeAll { completedIDs.contains($0.id) }
        for id in completedIDs { transferRetryActions.removeValue(forKey: id) }
    }

    func trimTransferHistory() {
        let completed = transfers.filter(\.isDone)
        let retainedCompletedIDs = Set(
            OperationResourceBudget.prefix(
                completed,
                maximumCount: OperationResourceBudget.sftpRetainedCompletedTransfers
            ).map(\.id)
        )
        transfers.removeAll { $0.isDone && !retainedCompletedIDs.contains($0.id) }
        transferRetryActions = transferRetryActions.filter { id, _ in
            transfers.contains(where: { $0.id == id })
        }
    }
}
