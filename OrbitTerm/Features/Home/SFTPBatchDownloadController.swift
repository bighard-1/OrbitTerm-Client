import Combine
import Foundation

/// Owns presentation until an explicitly cancelled download has really stopped.
/// Leaving the page/session revokes that ownership without releasing core I/O slots.
@MainActor
final class SFTPBatchDownloadController: ObservableObject {
    @Published private(set) var state = SFTPBrowserBatchState()
    private var owner = OperationOwner()
    private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    @discardableResult
    func start(
        items: [FileItem],
        operation: @escaping @MainActor ([FileItem]) async -> BatchDownloadResult
    ) -> Task<Void, Never>? {
        guard task == nil else { return nil }
        let files = SFTPBatchOperationFormatter.downloadableItems(from: items)
        guard !files.isEmpty else { return nil }
        let lease = owner.begin()
        state.beginDownload(total: files.count)
        let worker = Task { [weak self] in
            let result: BatchDownloadResult
            if Task.isCancelled {
                result = BatchDownloadResult(summary: .init(
                    failed: Dictionary(uniqueKeysWithValues: files.map { ($0.name, "传输已取消") })
                ), downloadedURLs: [])
            } else {
                result = await operation(files)
            }
            guard let self, self.owner.owns(lease) else { return }
            let wasCancelled = Task.isCancelled || self.state.isCancelling
            self.state.finishBatch(
                message: SFTPBatchOperationFormatter.downloadResultMessage(
                    for: result.summary, wasCancelled: wasCancelled
                ),
                downloadedURLs: result.downloadedURLs,
                wasCancelled: wasCancelled
            )
            self.task = nil
        }
        task = worker
        return worker
    }

    func requestCancellation() {
        guard let task else { return }
        state.requestCancellation()
        task.cancel()
    }

    func dismissResult() { state.isResultPresented = false }

    func takeCompletedDownloads() -> [URL] { state.takeCompletedDownloads() }

    func abandon() {
        owner.invalidate()
        task?.cancel()
        task = nil
        state.cancelBatch()
    }
}
