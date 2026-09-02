import Foundation

/// One place for bounded in-memory presentation and worker budgets.
/// Persistent, user-authored sync mutations are intentionally excluded from
/// destructive eviction: correctness takes precedence over a hard item cap.
enum OperationResourceBudget {
    static let terminalPendingBytesPerChannel = 1_048_576
    static let terminalReplayBytesPerChannel = 8_388_608
    static let terminalFlushIntervalNanoseconds: UInt64 = 33_000_000

    static let dockerRenderedLogBytes = 1_048_576
    static let dockerRefreshIntervalNanoseconds: UInt64 = 2_000_000_000

    static let monitorPointsPerPanel = 600
    static let monitorChartPoints = 180

    static let sftpMaximumConcurrentTransfers = 3
    static let sftpRetainedCompletedTransfers = 48

    /// Sync performs exactly one persisted mutation at a time. Incremental
    /// pages stay bounded; the durable queue itself is never discarded merely
    /// to meet a memory budget.
    static let syncMaximumConcurrentDeliveries = 1
    static let syncIncrementalPageSize = 100

    static func shouldYieldSyncDelivery(completedInSlice: Int) -> Bool {
        completedInSlice >= syncIncrementalPageSize
    }

    static func permitsSyncContinuation(
        hasMore: Bool,
        networkAvailable: Bool,
        authenticationMatchesExpectedAccount: Bool
    ) -> Bool {
        hasMore && networkAvailable && authenticationMatchesExpectedAccount
    }

    static func permitsSyncDelivery(activeDeliveries: Int) -> Bool {
        activeDeliveries < syncMaximumConcurrentDeliveries
    }

    static func tail(_ data: Data, maximumBytes: Int) -> Data {
        guard maximumBytes > 0, data.count > maximumBytes else { return data }
        return data.suffix(maximumBytes)
    }

    static func prefix<T>(_ values: [T], maximumCount: Int) -> [T] {
        guard maximumCount > 0 else { return [] }
        return Array(values.prefix(maximumCount))
    }
}

/// Stateful admission gate for bounded foreground worker queues. It contains
/// no task or service reference; callers retain cancellation and completion
/// ownership while this value guarantees that bursts cannot exceed the budget.
struct OperationConcurrencyGate {
    let maximumConcurrentOperations: Int
    private(set) var activeOperationCount = 0

    init(maximumConcurrentOperations: Int) {
        self.maximumConcurrentOperations = max(1, maximumConcurrentOperations)
    }

    mutating func acquire(requestedSlots: Int = 1) -> Int? {
        let requested = max(1, requestedSlots)
        let available = maximumConcurrentOperations - activeOperationCount
        let granted = min(requested, available)
        guard granted > 0 else { return nil }
        activeOperationCount += granted
        return granted
    }

    mutating func release(slots: Int = 1) {
        activeOperationCount = max(0, activeOperationCount - max(1, slots))
    }

    mutating func reset() {
        activeOperationCount = 0
    }
}
