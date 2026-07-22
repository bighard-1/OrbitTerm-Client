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
