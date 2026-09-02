#if os(macOS)
import AppKit
import Foundation

@MainActor
final class RemoteDesktopSessionController: ObservableObject {
    @Published private(set) var engineSession: FreeRDPEngineSession?
    @Published private(set) var phase: RemoteDesktopSessionPhase = .disconnected
    @Published var certificateChallenge: RemoteDesktopCertificateChallenge?
    @Published private(set) var failureMessage: String?

    var onUpdate: ((RemoteDesktopSessionUpdate) -> Void)?
    private let adapter: FreeRDPAdapter

    init() {
        self.adapter = FreeRDPAdapter()
    }

    init(adapter: FreeRDPAdapter) {
        self.adapter = adapter
    }

    func connect(to server: ServerEntry) async throws {
        await disconnect()
        guard server.transport == .rdp,
              let port = UInt16(exactly: server.port) else {
            throw RemoteDesktopFailureKind.invalidTarget
        }
        let profile = try RemoteDesktopConnectionProfile(
            assetID: server.id,
            host: server.host,
            port: port,
            targetPlatform: .windows,
            credentialID: server.credentialID,
            username: server.username,
            requireNLA: true
        )
        guard let engine = try await adapter.open(profile: profile) as? FreeRDPEngineSession else {
            throw RemoteDesktopFailureKind.engineUnavailable
        }
        engine.onUpdate = { [weak self, weak engine] update in
            guard let self else { return }
            self.phase = update.phase
            self.failureMessage = update.failure.map(Self.message(for:))
            if update.requiresCertificateDecision {
                self.certificateChallenge = engine?.certificateChallenge
            }
            self.onUpdate?(update)
        }
        engineSession = engine
        phase = .starting
        failureMessage = nil
        do {
            try engine.start()
        } catch {
            await engine.close()
            engineSession = nil
            phase = .failed
            failureMessage = "远程桌面工作线程启动失败。"
            throw error
        }
    }

    func acceptCertificateOnce() {
        certificateChallenge = nil
        Task { await engineSession?.acceptCertificateOnce() }
    }

    func rejectCertificate() {
        certificateChallenge = nil
        Task { await engineSession?.rejectCertificate() }
    }

    func reconnect() async {
        do {
            try await engineSession?.reconnect()
        } catch {
            failureMessage = "无法重新连接远程桌面，请检查网络和资产凭据。"
        }
    }

    func disconnect() async {
        certificateChallenge = nil
        await engineSession?.close()
        engineSession = nil
        phase = .disconnected
    }

    func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private static func message(for failure: RemoteDesktopFailureKind) -> String {
        switch failure {
        case .engineUnavailable: "远程桌面组件不可用或版本不匹配。"
        case .invalidTarget: "远程桌面地址或端口无效。"
        case .certificateRejected: "服务器证书未被接受，连接已取消。"
        case .authenticationFailed: "远程桌面凭据无效或无权登录。"
        case .networkUnavailable: "无法访问远程桌面服务。"
        case .timedOut: "远程桌面连接超时。"
        case .protocolError: "远程桌面协议协商失败，请检查 NLA、证书及服务器策略。"
        case .cancelled: "远程桌面连接已取消。"
        case .unknown: "远程桌面连接意外中断。"
        }
    }
}
#endif
