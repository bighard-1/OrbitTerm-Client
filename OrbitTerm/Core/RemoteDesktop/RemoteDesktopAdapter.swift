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
    let username: String
    let requireNLA: Bool

    init(
        assetID: UUID,
        host: String,
        port: UInt16,
        targetPlatform: RemoteDesktopTargetPlatform,
        credentialID: UUID,
        username: String = "",
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
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
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
    func acceptCertificateOnce() async
    func rejectCertificate() async
    func resize(width: Int, height: Int) async
    func send(text: String)
    func send(scancode: UInt32, pressed: Bool)
    func sendPointer(action: Int32, x: UInt16, y: UInt16, wheelDelta: Int16)
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

#if os(macOS)
struct RemoteDesktopCertificateChallenge: Identifiable, Equatable, Sendable {
    let id = UUID()
    let host: String
    let port: UInt16
    let commonName: String
    let subject: String
    let issuer: String
    let fingerprint: String
    let changed: Bool
}

@MainActor
final class FreeRDPAdapter: RemoteDesktopEngineAdapter {
    private let credentialVault: CredentialVault

    init(credentialVault: CredentialVault = .shared) {
        self.credentialVault = credentialVault
    }

    var capability: RemoteDesktopRuntimeCapability {
        FreeRDPRuntimeProbe.current().status == .available ? .available : .unavailable
    }

    func open(profile: RemoteDesktopConnectionProfile) async throws -> any RemoteDesktopEngineSession {
        guard capability == .available else { throw RemoteDesktopFailureKind.engineUnavailable }
        guard orbit_rdp_runtime_prepare() == ORBIT_RDP_OK else {
            throw RemoteDesktopFailureKind.engineUnavailable
        }
        guard let credentials = try credentialVault.read(for: profile.credentialID) else {
            throw RemoteDesktopFailureKind.authenticationFailed
        }
        return try FreeRDPEngineSession(profile: profile, credentials: credentials)
    }
}

private let freeRDPEventCallback: orbit_rdp_event_callback = { _, event, nativeError, userData in
    guard let userData else { return }
    let owner = Unmanaged<FreeRDPEngineSession>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in owner.receive(event: event.rawValue, nativeError: nativeError) }
}

private let freeRDPCertificateCallback: orbit_rdp_certificate_callback = { _, challenge, userData in
    guard let challenge, let userData else { return }
    func copied(_ value: UnsafePointer<CChar>?) -> String { value.map(String.init(cString:)) ?? "" }
    let copiedChallenge = RemoteDesktopCertificateChallenge(
        host: copied(challenge.pointee.host),
        port: challenge.pointee.port,
        commonName: copied(challenge.pointee.common_name),
        subject: copied(challenge.pointee.subject),
        issuer: copied(challenge.pointee.issuer),
        fingerprint: copied(challenge.pointee.fingerprint),
        changed: challenge.pointee.changed != 0
    )
    let owner = Unmanaged<FreeRDPEngineSession>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in owner.receive(certificate: copiedChallenge) }
}

private let freeRDPFrameCallback: orbit_rdp_frame_callback = { _, bytes, width, height, stride, userData in
    guard let bytes, let userData, width > 0, height > 0, stride >= width * 4 else { return }
    let (byteCount, overflow) = Int(stride).multipliedReportingOverflow(by: Int(height))
    guard !overflow, byteCount <= 1_073_741_824 else { return }
    let copied = Data(bytes: bytes, count: byteCount)
    let owner = Unmanaged<FreeRDPEngineSession>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in owner.receive(frameData: copied, width: Int(width), height: Int(height), stride: Int(stride)) }
}

@MainActor
final class FreeRDPEngineSession: ObservableObject, RemoteDesktopEngineSession {
    let frameBuffer = FreeRDPFrameBufferModel()
    @Published private(set) var phase: RemoteDesktopSessionPhase = .starting
    @Published private(set) var certificateChallenge: RemoteDesktopCertificateChallenge?
    @Published private(set) var lastNativeError: UInt32 = 0
    var onUpdate: ((RemoteDesktopSessionUpdate) -> Void)?

    let updates: AsyncStream<RemoteDesktopSessionUpdate>
    private let updateContinuation: AsyncStream<RemoteDesktopSessionUpdate>.Continuation
    private var nativeSession: OpaquePointer?
    private var closed = false
    private var certificateWasRejected = false

    init(profile: RemoteDesktopConnectionProfile, credentials: ServerCredentials) throws {
        var continuation: AsyncStream<RemoteDesktopSessionUpdate>.Continuation!
        updates = AsyncStream { continuation = $0 }
        updateContinuation = continuation

        let account = Self.splitAccount(profile.username)
        var password = credentials.password
        defer { SecurityPrimitives.secureZero(&password) }
        var created: OpaquePointer?
        let result = profile.host.withCString { host in
            account.username.withCString { username in
                password.withCString { secret in
                    account.domain.withCString { domain in
                        var options = orbit_rdp_session_options(
                            abi_version: orbit_rdp_abi_version(),
                            host: host,
                            port: profile.port,
                            desktop_width: 1440,
                            desktop_height: 900,
                            require_nla: profile.requireNLA ? 1 : 0,
                            username: username,
                            password: secret,
                            domain: domain
                        )
                        return orbit_rdp_session_create(&options, &created)
                    }
                }
            }
        }
        guard result == ORBIT_RDP_OK, let created else { throw RemoteDesktopFailureKind.engineUnavailable }
        nativeSession = created
        let userData = Unmanaged.passUnretained(self).toOpaque()
        guard orbit_rdp_session_set_callbacks(
            created,
            freeRDPEventCallback,
            freeRDPCertificateCallback,
            freeRDPFrameCallback,
            userData
        ) == ORBIT_RDP_OK else {
            orbit_rdp_session_free(created)
            nativeSession = nil
            throw RemoteDesktopFailureKind.engineUnavailable
        }
    }

    deinit {
        if let nativeSession { orbit_rdp_session_free(nativeSession) }
        updateContinuation.finish()
    }

    func start() throws {
        guard let nativeSession, !closed,
              orbit_rdp_session_start(nativeSession) == ORBIT_RDP_OK else {
            throw RemoteDesktopFailureKind.engineUnavailable
        }
    }

    func reconnect() async throws {
        guard let nativeSession, !closed,
              orbit_rdp_session_reconnect(nativeSession) == ORBIT_RDP_OK else {
            throw RemoteDesktopFailureKind.engineUnavailable
        }
    }

    func setFullScreen(_ enabled: Bool) async { _ = enabled }

    func acceptCertificateOnce() async {
        certificateWasRejected = false
        certificateChallenge = nil
        guard let nativeSession else { return }
        _ = orbit_rdp_session_decide_certificate(nativeSession, ORBIT_RDP_CERTIFICATE_ACCEPT_ONCE)
    }

    func rejectCertificate() async {
        certificateWasRejected = true
        certificateChallenge = nil
        guard let nativeSession else { return }
        _ = orbit_rdp_session_decide_certificate(nativeSession, ORBIT_RDP_CERTIFICATE_REJECT)
    }

    func resize(width: Int, height: Int) async {
        guard let nativeSession, width >= 320, height >= 200 else { return }
        _ = orbit_rdp_session_resize(nativeSession, UInt32(width), UInt32(height))
    }

    func send(text: String) {
        guard let nativeSession, !text.isEmpty else { return }
        let utf16 = Array(text.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            _ = orbit_rdp_session_send_unicode(nativeSession, buffer.baseAddress, buffer.count)
        }
    }

    func send(scancode: UInt32, pressed: Bool) {
        guard let nativeSession else { return }
        _ = orbit_rdp_session_send_scancode(nativeSession, scancode, pressed ? 1 : 0)
    }

    func sendPointer(action: Int32, x: UInt16, y: UInt16, wheelDelta: Int16 = 0) {
        guard let nativeSession else { return }
        let nativeAction = orbit_rdp_pointer_action(rawValue: UInt32(bitPattern: action))
        _ = orbit_rdp_session_send_pointer(nativeSession, nativeAction, x, y, wheelDelta)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        certificateChallenge = nil
        if let nativeSession { _ = orbit_rdp_session_stop(nativeSession) }
        receive(phase: .closed)
    }

    fileprivate func receive(event: UInt32, nativeError: UInt32) {
        lastNativeError = nativeError
        switch event {
        case 1: receive(phase: .starting)
        case 2: receive(phase: .authenticating)
        case 3: receive(phase: .connected)
        case 4: receive(phase: .reconnecting)
        case 5: receive(phase: .disconnected)
        case 6:
            let failure: RemoteDesktopFailureKind = certificateWasRejected
                ? .certificateRejected
                : Self.failure(for: nativeError)
            receive(phase: .failed, failure: failure)
        default: break
        }
    }

    fileprivate func receive(certificate: RemoteDesktopCertificateChallenge) {
        certificateChallenge = certificate
        receive(phase: .awaitingUserDecision, requiresCertificateDecision: true)
    }

    fileprivate func receive(frameData: Data, width: Int, height: Int, stride: Int) {
        guard !closed, let frame = try? RemoteDesktopFrame(
            width: width, height: height, stride: stride, bgraBytes: frameData
        ) else { return }
        try? frameBuffer.publish(frame)
    }

    private func receive(
        phase: RemoteDesktopSessionPhase,
        failure: RemoteDesktopFailureKind? = nil,
        requiresCertificateDecision: Bool = false
    ) {
        guard !closed || phase == .closed else { return }
        self.phase = phase
        let update = RemoteDesktopSessionUpdate(
            phase: phase,
            failure: failure,
            requiresCertificateDecision: requiresCertificateDecision
        )
        updateContinuation.yield(update)
        onUpdate?(update)
    }

    private static func splitAccount(_ value: String) -> (domain: String, username: String) {
        guard let slash = value.firstIndex(of: "\\") else { return ("", value) }
        return (String(value[..<slash]), String(value[value.index(after: slash)...]))
    }

    private static func failure(for nativeError: UInt32) -> RemoteDesktopFailureKind {
        switch orbit_rdp_classify_error(nativeError).rawValue {
        case 1: .authenticationFailed
        case 2: .networkUnavailable
        case 3: .timedOut
        case 4: .protocolError
        case 5: .cancelled
        default: .unknown
        }
    }
}
#endif

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
