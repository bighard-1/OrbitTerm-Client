import Foundation

enum SyncQueueDeliveryDisposition: Equatable, Sendable {
    case automaticRetry
    case waitForAuthentication
    case blocked
}

/// Queue behavior is derived only from stable, privacy-safe diagnostic codes.
enum SyncQueueRecoveryPolicy {
    static let blockedPrefix = "blocked:"
    static let maximumServiceUnavailableAttempts = 5

    static func disposition(
        for diagnosticCode: String,
        attemptCount: Int = 1
    ) -> SyncQueueDeliveryDisposition {
        switch diagnosticCode {
        case "sync.networkUnavailable", "sync.timedOut":
            return .automaticRetry
        case "sync.serviceUnavailable":
            return attemptCount <= maximumServiceUnavailableAttempts ? .automaticRetry : .blocked
        case "sync.requestRejected":
            return .blocked
        case "sync.authenticationExpired", "sync.passwordChangeRequired":
            return .waitForAuthentication
        default:
            return .blocked
        }
    }

    static func persistedError(
        diagnosticCode: String,
        disposition: SyncQueueDeliveryDisposition
    ) -> String {
        switch disposition {
        case .automaticRetry:
            diagnosticCode
        case .waitForAuthentication:
            "waiting_auth:\(diagnosticCode)"
        case .blocked:
            blockedPrefix + diagnosticCode
        }
    }

    static func effectiveRetryDelay(
        defaultBackoff: TimeInterval,
        serverSuggested: TimeInterval?
    ) -> TimeInterval {
        max(defaultBackoff, serverSuggested ?? 0)
    }
}

/// Persist only a bounded HTTP status alongside the stable recovery category.
/// Never copy a response body, URL, token, or server-controlled error text into
/// the durable queue. The existing `blocked:` prefix remains query-compatible.
enum SyncQueueFailureEvidence {
    static func persistedError(
        diagnosticCode: String,
        disposition: SyncQueueDeliveryDisposition,
        underlyingError: Error
    ) -> String {
        let category = SyncQueueRecoveryPolicy.persistedError(
            diagnosticCode: diagnosticCode,
            disposition: disposition
        )
        guard let networkError = underlyingError as? NetworkService.NetworkError else {
            return category
        }
        let statusCode: Int
        switch networkError {
        case let .httpStatus(code, _), let .unexpectedStatus(code):
            statusCode = code
        case .requestTooLarge:
            statusCode = 413
        default:
            return category
        }
        guard (400 ... 599).contains(statusCode) else { return category }
        return "\(category)|http=\(statusCode)"
    }
}

/// A fresh, authenticated pull can prove that an old rejected delete has
/// already reached its intended state. Never infer this from local metadata
/// alone: it may be stale while another device has restored the asset.
struct ConfirmedRemoteTombstone: Sendable {
    let assetID: UUID
    let state: String
    let vectorClock: String
    let serverRevision: UInt64
}

enum SyncQueueTombstoneReconciliationPolicy {
    static let blockedConflictCode = "blocked:sync.requestRejected|http=409"

    static func mayAcknowledge(
        queuedAssetID: UUID,
        queuedVectorClock: String,
        persistedError: String?,
        remote: ConfirmedRemoteTombstone
    ) -> Bool {
        guard persistedError == blockedConflictCode,
              remote.serverRevision > 0,
              (remote.state == "deleted" || remote.state == "purged"),
              queuedAssetID == remote.assetID else { return false }
        return clock(remote.vectorClock, covers: queuedVectorClock)
    }

    private static func clock(_ remoteRaw: String, covers queuedRaw: String) -> Bool {
        guard let remote = try? JSONDecoder().decode([String: Int64].self, from: Data(remoteRaw.utf8)),
              let queued = try? JSONDecoder().decode([String: Int64].self, from: Data(queuedRaw.utf8)),
              !remote.isEmpty, !queued.isEmpty,
              remote.values.allSatisfy({ $0 >= 0 }),
              queued.values.allSatisfy({ $0 >= 0 }) else { return false }
        return queued.allSatisfy { entry in
            (remote[entry.key] ?? -1) >= entry.value
        }
    }
}

enum SyncQueueAccountTransitionPolicy {
    static func invalidatesCurrentDelivery(previous: String?, next: String?) -> Bool {
        previous != next
    }
}

/// Converts wall-clock samples into a process-local trusted clock. Retry
/// deadlines remain durable wall-clock values across launches, while an
/// in-process manual clock jump cannot make an existing server delay expire
/// early (or extend it indefinitely). System uptime includes device sleep.
final class RetryClockGuard {
    private let lock = NSLock()
    private let toleratedWallClockDrift: TimeInterval
    private var lastUptime: TimeInterval?
    private var lastTrustedUnix: TimeInterval?

    init(toleratedWallClockDrift: TimeInterval = 2) {
        self.toleratedWallClockDrift = max(0, toleratedWallClockDrift)
    }

    func trustedNow(
        wallClock: Date = Date(),
        systemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Date {
        lock.lock()
        defer { lock.unlock() }

        let wallUnix = wallClock.timeIntervalSince1970
        guard let previousUptime = lastUptime,
              let previousTrustedUnix = lastTrustedUnix else {
            lastUptime = systemUptime
            lastTrustedUnix = wallUnix
            return wallClock
        }

        let uptimeDelta = systemUptime - previousUptime
        guard uptimeDelta >= 0 else {
            // Defensive reset for a new boot/sample source. The persisted
            // deadline remains authoritative across the process boundary.
            lastUptime = systemUptime
            lastTrustedUnix = wallUnix
            return wallClock
        }

        let monotonicCandidate = previousTrustedUnix + uptimeDelta
        let wallDrift = wallUnix - monotonicCandidate
        let trustedUnix: TimeInterval
        if abs(wallDrift) <= toleratedWallClockDrift {
            trustedUnix = max(previousTrustedUnix, wallUnix)
        } else {
            trustedUnix = monotonicCandidate
        }
        lastUptime = systemUptime
        lastTrustedUnix = trustedUnix
        return Date(timeIntervalSince1970: trustedUnix)
    }
}
