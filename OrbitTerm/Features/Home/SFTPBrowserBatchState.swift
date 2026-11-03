import Foundation

struct SFTPBrowserBatchState {
    var selectedIDs: Set<String> = []
    var isDeleteConfirmPresented = false
    var isRunning = false
    var isCancelling = false
    var progress: BatchDownloadProgress?
    var resultMessage: String = ""
    var isResultPresented = false
    private(set) var completedDownloadURLs: [URL] = []

    var hasSelection: Bool {
        !selectedIDs.isEmpty
    }

    mutating func toggleSelection(_ item: FileItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    func contains(_ item: FileItem) -> Bool {
        selectedIDs.contains(item.id)
    }

    mutating func clearSelection() {
        selectedIDs.removeAll()
    }

    mutating func requestDeleteConfirmation() {
        isDeleteConfirmPresented = true
    }

    mutating func beginDownload(total: Int) {
        isRunning = true
        isCancelling = false
        isResultPresented = false
        completedDownloadURLs = []
        progress = BatchDownloadProgress(completed: 0, total: total, bytesTransferred: 0, currentFile: "")
    }

    mutating func updateProgress(_ nextProgress: BatchDownloadProgress) {
        guard isRunning, !isCancelling else { return }
        progress = nextProgress
    }

    mutating func requestCancellation() {
        guard isRunning else { return }
        // Keep the selection and busy state until the worker acknowledges
        // cancellation, including completion of destination cleanup.
        isCancelling = true
    }

    mutating func showResult(_ message: String) {
        resultMessage = message
        isResultPresented = true
    }

    mutating func finishBatch(message: String, downloadedURLs: [URL] = [], wasCancelled: Bool = false) {
        isRunning = false
        isCancelling = false
        progress = nil
        clearSelection()
        // Offer export only after the result is dismissed. Presenting an alert
        // and a system share sheet in the same update can suppress both on iOS.
        completedDownloadURLs = wasCancelled ? [] : downloadedURLs
        showResult(message)
    }

    mutating func takeCompletedDownloads() -> [URL] {
        guard !isResultPresented, !isRunning else { return [] }
        let urls = completedDownloadURLs
        completedDownloadURLs = []
        return urls
    }

    mutating func cancelBatch() {
        isRunning = false
        isCancelling = false
        progress = nil
        isResultPresented = false
        completedDownloadURLs = []
        clearSelection()
    }
}
