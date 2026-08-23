import Foundation

/// Static hardware and operating-system facts sampled alongside a monitor point.
/// It is intentionally a value type so UI presentation does not depend on a service.
struct MonitorSystemInfo: Hashable, Codable, Sendable {
    let osName: String
    let cpuCoreCount: UInt32
    let cpuThreadCount: UInt32
    let memoryTotalMB: UInt64
    let swapTotalMB: UInt64
    let swapUsedMB: UInt64
    let diskTotalMB: UInt64
    let diskUsedMB: UInt64

    static let unavailable = MonitorSystemInfo(
        osName: "系统信息暂不可用",
        cpuCoreCount: 0,
        cpuThreadCount: 0,
        memoryTotalMB: 0,
        swapTotalMB: 0,
        swapUsedMB: 0,
        diskTotalMB: 0,
        diskUsedMB: 0
    )

    private enum CodingKeys: String, CodingKey {
        case osName = "os_name"
        case cpuCoreCount = "cpu_core_count"
        case cpuThreadCount = "cpu_thread_count"
        case memoryTotalMB = "memory_total_mb"
        case swapTotalMB = "swap_total_mb"
        case swapUsedMB = "swap_used_mb"
        case diskTotalMB = "disk_total_mb"
        case diskUsedMB = "disk_used_mb"
    }
}

/// Pure monitoring presentation policies are colocated with the snapshot
/// model so application and contract-test targets exercise exactly the same
/// tcping and preference behavior.
enum TCPLatencySamplePolicy {
    struct Statistics: Equatable {
        let attemptedCount: Int
        let successfulCount: Int
        let failurePercent: Double?
        let p50Milliseconds: Double?
        let p95Milliseconds: Double?
    }

    static func stabilized(current: Double?, recent: [Double?]) -> Double? {
        guard let current, current.isFinite, current >= 0 else { return nil }
        var samples = recent.suffix(2).compactMap { value -> Double? in
            guard let value, value.isFinite, value >= 0 else { return nil }
            return value
        }
        samples.append(current)
        samples.sort()
        return samples[samples.count / 2]
    }

    /// TCP probe failures are connection attempts that timed out or could not
    /// complete. They are deliberately not described as packet loss because a
    /// firewall, a busy sshd or a filtered port can produce the same result.
    static func statistics(samples: [Double?]) -> Statistics {
        let valid = samples.compactMap { value -> Double? in
            guard let value, value.isFinite, value >= 0 else { return nil }
            return value
        }.sorted()
        let failurePercent = samples.isEmpty
            ? nil
            : Double(samples.count - valid.count) / Double(samples.count) * 100
        return Statistics(
            attemptedCount: samples.count,
            successfulCount: valid.count,
            failurePercent: failurePercent,
            p50Milliseconds: percentile(valid, percentile: 0.50),
            p95Milliseconds: percentile(valid, percentile: 0.95)
        )
    }

    private static func percentile(_ sorted: [Double], percentile: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = max(0, min(sorted.count - 1, Int(ceil(percentile * Double(sorted.count))) - 1))
        return sorted[rank]
    }
}

enum MonitorRefreshPreference {
    static let storageKey = "orbitterm.monitor.autoRefresh.enabled"

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.object(forKey: storageKey) == nil || userDefaults.bool(forKey: storageKey)
    }
}
