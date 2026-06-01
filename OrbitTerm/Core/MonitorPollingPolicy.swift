import Foundation

enum MonitorPollingPolicy {
    static let minimumInterval: TimeInterval = 1.0
    static let maximumInterval: TimeInterval = 10.0
    static let defaultInterval: TimeInterval = 1.0
    static let reconnectBackoffSeconds: [UInt64] = [2, 5, 10, 20, 30]

    static func configuredInterval(userDefaults: UserDefaults = .standard, key: String) -> TimeInterval {
        let stored = userDefaults.double(forKey: key)
        let interval = stored == 0 ? defaultInterval : stored
        return max(minimumInterval, min(maximumInterval, interval))
    }

    static func delayAfterRequest(startedAt: Date, interval: TimeInterval, now: Date = Date()) -> TimeInterval {
        max(0, interval - now.timeIntervalSince(startedAt))
    }

    static func shouldAutoHeal(error: Error, failureCount: Int) -> Bool {
        guard failureCount >= 2 else { return false }
        if case let SFTPError.rustError(message) = error {
            let lower = message.lowercased()
            if lower.contains("auth") || lower.contains("permission denied") || lower.contains("private key") {
                return false
            }
        }
        return true
    }
}
