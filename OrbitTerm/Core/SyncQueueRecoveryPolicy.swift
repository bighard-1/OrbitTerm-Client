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
        case "sync.authenticationExpired":
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
