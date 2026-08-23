import Foundation

/// The non-secret owner that is entitled to publish an asynchronous result.
/// Scopes deliberately use opaque IDs only; they must never be logged as a
/// substitute for host, account, credential, or UI state.
enum OperationScope: Hashable, Sendable {
    case anonymous
    case account(String)
    case workspace(UUID)
    case terminalChannel(UInt64)
}

/// A value token identifying one owner-controlled asynchronous operation.
/// It carries no service, task, credential, or UI reference, so it is safe to
/// use as a small generation fence at presentation boundaries.
struct OperationLease: Hashable, Sendable {
    fileprivate let generation: UUID
    fileprivate let scope: OperationScope
}

/// Pure generation gate for one logical operation stream.
///
/// Starting a new lease or invalidating the owner makes every earlier lease
/// stale. Callers remain responsible for cancelling underlying work when the
/// API supports it; this type guarantees that late completion cannot publish
/// state after ownership changed.
struct OperationOwner: Sendable {
    private var activeGeneration = UUID()
    private var activeScope: OperationScope = .anonymous

    mutating func begin(scope: OperationScope = .anonymous) -> OperationLease {
        let lease = OperationLease(generation: UUID(), scope: scope)
        activeGeneration = lease.generation
        activeScope = scope
        return lease
    }

    mutating func invalidate() {
        activeGeneration = UUID()
    }

    func owns(_ lease: OperationLease) -> Bool {
        activeGeneration == lease.generation && activeScope == lease.scope
    }

    /// Verifies both the generation and the intended account/session/channel
    /// boundary. This makes a late completion from a recycled session ID or a
    /// replaced account ineligible to publish UI state.
    func owns(_ lease: OperationLease, scope: OperationScope) -> Bool {
        owns(lease) && lease.scope == scope
    }
}

/// Centralizes the bounded-worker rule used by long-running local operation
/// queues. It is deliberately pure so the policy can be verified without a
/// network, FFI handle, or UI fixture.
enum OperationConcurrencyPolicy {
    static func workerCount(
        requested: Int,
        itemCount: Int,
        maximum: Int
    ) -> Int {
        guard itemCount > 0, maximum > 0 else { return 0 }
        return min(max(1, requested), maximum, itemCount)
    }
}

/// Why a page-owned operation was made ineligible to update presentation.
/// The reason is deliberately non-sensitive: it is suitable for policy and
/// regression tests, but must not be exported as diagnostics for an account
/// or remote host.
enum PageOperationCancellationReason: Equatable, Sendable {
    case replaced
    case userCancelled
    case pageDisappeared
    case sceneInactive
    case accountLocked
    case accountSignedOut
    case accountChanged
    case timedOut
}

/// A lease for an operation started by a SwiftUI page.
///
/// It contains only a generation fence, an opaque scope, and a deadline. It
/// intentionally has no View, service, credential, or Task reference, so a
/// late callback cannot retain a page or publish across an account boundary.
struct PageOperationLease: Hashable, Sendable {
    fileprivate let operationLease: OperationLease
    let deadline: Date
}

/// Small presentation owner for user-triggered page work.
///
/// Views retain their actual `Task` so they can cancel the underlying API call
/// on disappearance. This value supplies the common account/page generation
/// fence and deadline check used before any UI state is published.
struct PageOperationOwner: Sendable {
    private var owner = OperationOwner()
    private(set) var cancellationReason: PageOperationCancellationReason?

    mutating func begin(
        scope: OperationScope,
        timeout: TimeInterval
    ) -> PageOperationLease {
        cancellationReason = nil
        return PageOperationLease(
            operationLease: owner.begin(scope: scope),
            deadline: Date().addingTimeInterval(max(0, timeout))
        )
    }

    mutating func cancel(_ reason: PageOperationCancellationReason) {
        cancellationReason = reason
        owner.invalidate()
    }

    func accepts(_ lease: PageOperationLease, scope: OperationScope, now: Date = Date()) -> Bool {
        now < lease.deadline && owner.owns(lease.operationLease, scope: scope)
    }

    func timeoutReached(_ lease: PageOperationLease, now: Date = Date()) -> Bool {
        now >= lease.deadline
    }
}

/// Shared upper bounds for foreground actions. Individual services can have a
/// tighter protocol timeout; this fence guarantees that a slow user action
/// cannot later update a page that has been replaced, locked, or signed out.
enum PageOperationTimeout {
    static let authentication: TimeInterval = 30
    static let assetMutation: TimeInterval = 30
    static let batchCommand: TimeInterval = 120
    static let dockerLogFetch: TimeInterval = 15

    static func perform<Value>(
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                throw PageOperationTimeoutError.expired
            }

            guard let value = try await group.next() else {
                throw PageOperationTimeoutError.expired
            }
            group.cancelAll()
            return value
        }
    }
}

enum PageOperationTimeoutError: Error {
    case expired
}
