import Foundation
import os

/// Non-content performance markers for Instruments. These markers must never
/// carry server identity, account identity, paths, commands, terminal output,
/// error text or request data.
enum PerformanceSignpost {
    enum Scenario: String {
        case launch = "app_launch"
        case unlock = "unlock"
        case terminalFirstFrame = "terminal_first_frame"
        case dockerLogRefresh = "docker_log_refresh"
        case monitorRefresh = "monitor_refresh"
        case sftpDirectoryRefresh = "sftp_directory_refresh"
        case syncRoundTrip = "sync_round_trip"
        case syncRemotePull = "sync_remote_pull"
        case syncPreparation = "sync_preparation"

        fileprivate var name: StaticString {
            switch self {
            case .launch: return "AppLaunch"
            case .unlock: return "Unlock"
            case .terminalFirstFrame: return "TerminalFirstFrame"
            case .dockerLogRefresh: return "DockerLogRefresh"
            case .monitorRefresh: return "MonitorRefresh"
            case .sftpDirectoryRefresh: return "SFTPDirectoryRefresh"
            case .syncRoundTrip: return "SyncRoundTrip"
            case .syncRemotePull: return "SyncRemotePull"
            case .syncPreparation: return "SyncPreparation"
            }
        }
    }

    final class Span: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private let scenario: Scenario
        private let signpostID: OSSignpostID

        fileprivate init(scenario: Scenario, signpostID: OSSignpostID) {
            self.scenario = scenario
            self.signpostID = signpostID
        }

        func finish() {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return }
            completed = true
            os_signpost(.end, log: PerformanceSignpost.log, name: scenario.name, signpostID: signpostID)
        }

        func cancel() {
            // Keep the interval balanced without including a user-visible
            // reason. The exact cancellation reason belongs to the existing
            // typed operation state, not to a performance trace.
            finish()
        }
    }

    // PointsOfInterest is the documented Instruments category that is
    // collected without a per-trace dynamic-subsystem override. The event
    // names remain the only payload and intentionally carry no user data.
    private static let log = OSLog(
        subsystem: "com.orbitterm.app",
        category: .pointsOfInterest
    )

    static func begin(_ scenario: Scenario) -> Span {
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: scenario.name, signpostID: signpostID)
        return Span(scenario: scenario, signpostID: signpostID)
    }
}
