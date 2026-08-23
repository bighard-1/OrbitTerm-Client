import Foundation

/// A deliberately small, privacy-safe contract for release-candidate device
/// performance evidence. Values describe the client process only; remote
/// server latency, asset names, paths and terminal content are never inputs.
enum DevicePerformanceScenario: String, CaseIterable, Codable {
    case coldLaunch = "cold_launch"
    case unlock = "unlock"
    case terminalFirstFrame = "terminal_first_frame"
    case terminalLongOutput = "terminal_long_output"
    case dockerLogRefresh = "docker_log_refresh"
    case monitorRefresh = "monitor_refresh"
    case sftpDirectoryRefresh = "sftp_directory_refresh"
    case syncRoundTrip = "sync_round_trip"
}

struct DevicePerformanceSLO: Equatable, Codable {
    let maximumResponseMilliseconds: Double
    let maximumAverageCPUPercent: Double
    let maximumPeakFootprintBytes: Int
    let minimumFramesPerSecond: Double
    let maximumAnimationHitches: Int

    static func requirement(for scenario: DevicePerformanceScenario) -> Self {
        switch scenario {
        case .coldLaunch:
            .init( maximumResponseMilliseconds: 3_500, maximumAverageCPUPercent: 85, maximumPeakFootprintBytes: 360 * 1_024 * 1_024, minimumFramesPerSecond: 45, maximumAnimationHitches: 2 )
        case .unlock:
            .init( maximumResponseMilliseconds: 2_000, maximumAverageCPUPercent: 90, maximumPeakFootprintBytes: 360 * 1_024 * 1_024, minimumFramesPerSecond: 45, maximumAnimationHitches: 1 )
        case .terminalFirstFrame:
            .init( maximumResponseMilliseconds: 3_500, maximumAverageCPUPercent: 75, maximumPeakFootprintBytes: 420 * 1_024 * 1_024, minimumFramesPerSecond: 45, maximumAnimationHitches: 2 )
        case .terminalLongOutput:
            .init( maximumResponseMilliseconds: 250, maximumAverageCPUPercent: 80, maximumPeakFootprintBytes: 440 * 1_024 * 1_024, minimumFramesPerSecond: 45, maximumAnimationHitches: 3 )
        case .dockerLogRefresh, .monitorRefresh, .sftpDirectoryRefresh, .syncRoundTrip:
            .init( maximumResponseMilliseconds: 3_500, maximumAverageCPUPercent: 70, maximumPeakFootprintBytes: 420 * 1_024 * 1_024, minimumFramesPerSecond: 45, maximumAnimationHitches: 2 )
        }
    }
}

/// A sanitized summary derived from Instruments. The trace itself remains a
/// local/release-artifact attachment; it is never included in diagnostics.
struct DevicePerformanceSample: Equatable, Codable {
    let scenario: DevicePerformanceScenario
    let responseMilliseconds: Double
    let averageCPUPercent: Double
    let peakFootprintBytes: Int
    let minimumFramesPerSecond: Double
    let animationHitches: Int
}

enum DevicePerformanceSLOViolation: String, CaseIterable, Hashable {
    case responseTime
    case averageCPU
    case memoryFootprint
    case frameRate
    case animationHitches
}

enum DevicePerformanceSLOEvaluator {
    static func violations(for sample: DevicePerformanceSample) -> [DevicePerformanceSLOViolation] {
        let slo = DevicePerformanceSLO.requirement(for: sample.scenario)
        var violations: [DevicePerformanceSLOViolation] = []
        if sample.responseMilliseconds > slo.maximumResponseMilliseconds {
            violations.append(.responseTime)
        }
        if sample.averageCPUPercent > slo.maximumAverageCPUPercent {
            violations.append(.averageCPU)
        }
        if sample.peakFootprintBytes > slo.maximumPeakFootprintBytes {
            violations.append(.memoryFootprint)
        }
        if sample.minimumFramesPerSecond < slo.minimumFramesPerSecond {
            violations.append(.frameRate)
        }
        if sample.animationHitches > slo.maximumAnimationHitches {
            violations.append(.animationHitches)
        }
        return violations
    }
}
