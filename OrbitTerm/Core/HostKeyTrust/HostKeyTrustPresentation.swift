import Foundation

enum HostKeyTrustAction: String, Hashable, Sendable {
    case cancel
    case trustThisHost
    case close
    case copyFingerprints
    case retrySave
}

struct HostKeyChallengePresentation: Hashable, Sendable {
    let host: String
    let port: UInt16
    let algorithm: String
    let fingerprint: String
    let isPersisting: Bool
    let isExpired: Bool
    let actions: Set<HostKeyTrustAction>

    init(
        payload: HostKeyChallengePayload,
        isPersisting: Bool = false,
        nowUnix: UInt64 = UInt64(Date().timeIntervalSince1970)
    ) {
        host = payload.host
        port = payload.port
        algorithm = payload.keyAlgorithm
        fingerprint = payload.fingerprintSHA256
        self.isPersisting = isPersisting
        isExpired = payload.expiresAtUnix <= nowUnix
        actions = isExpired ? [.cancel] : [.cancel, .trustThisHost]
    }
}

struct HostKeyBlockedPresentation: Hashable, Sendable {
    enum Severity: Hashable, Sendable {
        case changed
        case revoked
        case unsupported
    }

    let severity: Severity
    let host: String
    let port: UInt16
    let algorithm: String
    let presentedFingerprint: String
    let previousFingerprint: String?
    let actions: Set<HostKeyTrustAction> = [.close, .copyFingerprints]

    init(payload: HostKeyBlockedPayload) {
        switch payload.reasonCode {
        case .changed: severity = .changed
        case .revoked: severity = .revoked
        case .unsupported, .certAuthorityUnsupported, .unknown: severity = .unsupported
        }
        host = payload.host
        port = payload.port
        algorithm = payload.keyAlgorithm
        presentedFingerprint = payload.presentedFingerprintSHA256
        previousFingerprint = payload.previousFingerprintSHA256
    }

    var copyText: String {
        [previousFingerprint, presentedFingerprint]
            .compactMap { $0 }
            .joined(separator: "\n")
    }
}

struct HostKeySaveErrorPresentation: Hashable, Sendable {
    let title = "无法保存服务器信任信息"
    let message = "OrbitTerm 无法保存此服务器密钥，因此没有尝试建立连接。"
    let actions: Set<HostKeyTrustAction> = [.retrySave, .cancel]
}
