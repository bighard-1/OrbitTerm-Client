import Foundation

struct RustSystemStatsPayload: Decodable {
    let sampledAtUnix: UInt64
    let cpuUsagePercent: Double
    let memAvailableMb: UInt64
    let memUsedPercent: Double
    let diskUsedPercent: Double
    let pingLatencyMs: Double?
    let rxRateKbps: Double
    let txRateKbps: Double

    enum CodingKeys: String, CodingKey {
        case sampledAtUnix = "sampled_at_unix"
        case cpuUsagePercent = "cpu_usage_percent"
        case memAvailableMb = "mem_available_mb"
        case memUsedPercent = "mem_used_percent"
        case diskUsedPercent = "disk_used_percent"
        case pingLatencyMs = "ping_latency_ms"
        case rxRateKbps = "rx_rate_kbps"
        case txRateKbps = "tx_rate_kbps"
    }

    var monitorPoint: MonitorPoint {
        MonitorPoint(
            time: Date(timeIntervalSince1970: TimeInterval(sampledAtUnix)),
            cpuUsage: cpuUsagePercent,
            memUsedPercent: memUsedPercent,
            diskUsedPercent: diskUsedPercent,
            pingLatencyMs: pingLatencyMs,
            rxRateKBps: rxRateKbps,
            txRateKBps: txRateKbps
        )
    }
}
