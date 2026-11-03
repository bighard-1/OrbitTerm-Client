import Foundation

/// Cancellation survives a connection-generation change and can be observed
/// by the worker without retaining a manager, view, or session credential.
final class SFTPTransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

struct SFTPTransferOperation: Sendable {
    let id = UUID()
    let slots: Int
    let cancellation = SFTPTransferCancellation()
}

/// Invalidating a connection requests cancellation, but does not release its
/// workers. Only an acknowledged worker exit releases its own reservation.
/// This keeps a rapid reconnect within the budget while old I/O is stopping.
struct SFTPTransferOperationRegistry {
    private var gate: OperationConcurrencyGate
    private var operations: [UUID: SFTPTransferOperation] = [:]

    init(maximumConcurrentOperations: Int) {
        gate = OperationConcurrencyGate(maximumConcurrentOperations: maximumConcurrentOperations)
    }

    var activeOperationCount: Int { gate.activeOperationCount }

    mutating func begin(requestedSlots: Int = 1) -> SFTPTransferOperation? {
        guard let slots = gate.acquire(requestedSlots: requestedSlots) else { return nil }
        let operation = SFTPTransferOperation(slots: slots)
        operations[operation.id] = operation
        return operation
    }

    func cancelAll() {
        for operation in operations.values { operation.cancellation.cancel() }
    }

    mutating func finish(_ operation: SFTPTransferOperation) {
        guard let owned = operations.removeValue(forKey: operation.id) else { return }
        gate.release(slots: owned.slots)
    }
}
