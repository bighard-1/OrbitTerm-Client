import Combine
import Foundation

/// Owns the sequential picker queue, while each manager retains its actual I/O
/// reservation until cancellation and remote cleanup have been acknowledged.
@MainActor
final class SFTPUploadQueueController: ObservableObject {
    @Published private(set) var isRunning = false
    private var owner = OperationOwner()
    private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    @discardableResult
    func start(
        urls: [URL],
        canContinue: @escaping @MainActor () -> Bool,
        operation: @escaping @MainActor (URL) async -> Void
    ) -> Task<Void, Never>? {
        guard task == nil, !urls.isEmpty, canContinue() else { return nil }
        let lease = owner.begin()
        isRunning = true
        let worker = Task { [weak self] in
            for url in urls {
                guard !Task.isCancelled, self?.owner.owns(lease) == true,
                      canContinue() else { break }
                await operation(url)
            }
            guard let self, self.owner.owns(lease) else { return }
            self.task = nil
            self.isRunning = false
        }
        task = worker
        return worker
    }

    func abandon() {
        owner.invalidate()
        task?.cancel()
        task = nil
        isRunning = false
    }
}
