import Foundation

struct SFTPBrowserBatchState {
    var selectedIDs: Set<String> = []
    var isDeleteConfirmPresented = false
    var isRunning = false
    var progress: BatchDownloadProgress?
    var resultMessage: String = ""
    var isResultPresented = false

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
        progress = BatchDownloadProgress(completed: 0, total: total, bytesTransferred: 0, currentFile: "")
    }

    mutating func updateProgress(_ nextProgress: BatchDownloadProgress) {
        progress = nextProgress
    }

    mutating func showResult(_ message: String) {
        resultMessage = message
        isResultPresented = true
    }

    mutating func finishBatch(message: String) {
        isRunning = false
        clearSelection()
        showResult(message)
    }
}
