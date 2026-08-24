import Foundation

enum RemoteDesktopTargetPlatform: String, Codable, Sendable {
    case windows
    case linux
    case macOS = "macos"

    var isSupported: Bool { self == .windows || self == .linux }
}

enum RemoteDesktopSessionPhase: String, Codable, Sendable {
    case starting
    case authenticating
    case awaitingUserDecision
    case connected
    case reconnecting
    case disconnected
    case failed
    case closed
}

enum RemoteDesktopFailureKind: String, Codable, Error, Sendable {
    case engineUnavailable
    case invalidTarget
    case certificateRejected
    case authenticationFailed
    case networkUnavailable
    case timedOut
    case protocolError
    case cancelled
    case unknown
}

struct RemoteDesktopConnectionProfile: Equatable, Sendable {
    let assetID: UUID
    let host: String
    let port: UInt16
    let targetPlatform: RemoteDesktopTargetPlatform
    let credentialID: UUID
    let requireNLA: Bool

    init(
        assetID: UUID,
        host: String,
        port: UInt16,
        targetPlatform: RemoteDesktopTargetPlatform,
        credentialID: UUID,
        requireNLA: Bool = true
    ) throws {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty, port > 0 else { throw RemoteDesktopFailureKind.invalidTarget }
        guard targetPlatform.isSupported else { throw RemoteDesktopFailureKind.invalidTarget }
        self.assetID = assetID
        self.host = normalizedHost
        self.port = port
        self.targetPlatform = targetPlatform
        self.credentialID = credentialID
        self.requireNLA = requireNLA
    }
}

struct RemoteDesktopSessionUpdate: Equatable, Sendable {
    let phase: RemoteDesktopSessionPhase
    let failure: RemoteDesktopFailureKind?
    let requiresCertificateDecision: Bool

    init(
        phase: RemoteDesktopSessionPhase,
        failure: RemoteDesktopFailureKind? = nil,
        requiresCertificateDecision: Bool = false
    ) {
        self.phase = phase
        self.failure = failure
        self.requiresCertificateDecision = requiresCertificateDecision
    }
}

enum RemoteDesktopRuntimeCapability: Equatable, Sendable {
    case available
    case unavailable
}

enum FreeRDPRuntimeStatus: Equatable, Sendable {
    case available
    case unavailable
    case versionMismatch
}

struct FreeRDPRuntimeInfo: Equatable, Sendable {
    let abiVersion: UInt32
    let expectedVersion: String
    let actualVersion: String?
    let status: FreeRDPRuntimeStatus
}

/// Reads only the audited embedded FreeRDP runtime. It never downloads code,
/// accepts certificates, opens sockets or reads credentials.
enum FreeRDPRuntimeProbe {
    static func current() -> FreeRDPRuntimeInfo {
        let expectedVersion = String(cString: orbit_rdp_expected_freerdp_version())
        var versionBytes = [CChar](repeating: 0, count: 64)
        let rawStatus = versionBytes.withUnsafeMutableBufferPointer { buffer in
            orbit_rdp_runtime_probe(buffer.baseAddress, buffer.count).rawValue
        }
        let actualVersion = versionBytes.first == 0 ? nil : String(cString: versionBytes)
        let status: FreeRDPRuntimeStatus
        switch rawStatus {
        case 1:
            status = .available
        case 2:
            status = .versionMismatch
        default:
            status = .unavailable
        }
        return FreeRDPRuntimeInfo(
            abiVersion: orbit_rdp_abi_version(),
            expectedVersion: expectedVersion,
            actualVersion: actualVersion,
            status: status
        )
    }
}

@MainActor
protocol RemoteDesktopEngineSession: AnyObject {
    var updates: AsyncStream<RemoteDesktopSessionUpdate> { get }
    func reconnect() async throws
    func setFullScreen(_ enabled: Bool) async
    func close() async
}

@MainActor
protocol RemoteDesktopEngineAdapter {
    var capability: RemoteDesktopRuntimeCapability { get }
    func open(profile: RemoteDesktopConnectionProfile) async throws -> any RemoteDesktopEngineSession
}

/// Fail-closed adapter used until the audited FreeRDP binary is linked on the platform.
/// It deliberately accepts no credential bytes and can never fall back to SSH.
@MainActor
struct DeferredFreeRDPAdapter: RemoteDesktopEngineAdapter {
    let capability: RemoteDesktopRuntimeCapability = .unavailable

    func open(profile: RemoteDesktopConnectionProfile) async throws -> any RemoteDesktopEngineSession {
        _ = profile
        throw RemoteDesktopFailureKind.engineUnavailable
    }
}

struct RemoteDesktopSessionStateMachine: Sendable {
    private(set) var phase: RemoteDesktopSessionPhase = .starting

    mutating func transition(to next: RemoteDesktopSessionPhase) -> Bool {
        guard Self.allowedTransitions[phase, default: []].contains(next) else { return false }
        phase = next
        return true
    }

    private static let allowedTransitions: [RemoteDesktopSessionPhase: Set<RemoteDesktopSessionPhase>] = [
        .starting: [.authenticating, .awaitingUserDecision, .failed, .closed],
        .authenticating: [.awaitingUserDecision, .connected, .reconnecting, .failed, .closed],
        .awaitingUserDecision: [.authenticating, .connected, .reconnecting, .failed, .closed],
        .connected: [.reconnecting, .disconnected, .failed, .closed],
        .reconnecting: [.authenticating, .awaitingUserDecision, .connected, .disconnected, .failed, .closed],
        .disconnected: [.reconnecting, .closed],
        .failed: [.reconnecting, .closed],
        .closed: []
    ]
}
