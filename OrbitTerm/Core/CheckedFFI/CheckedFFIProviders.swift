import Foundation

struct CheckedCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let password: String
    let privateKey: String
    let privateKeyPassphrase: String
    let allowPasswordFallback: Bool

    var description: String { "CheckedCredentials([REDACTED])" }
    var debugDescription: String { description }
}

protocol CheckedCredentialProvider: Sendable {
    func credentials(for reference: CredentialAccessReference) async throws -> CheckedCredentials
}

protocol KnownHostsPathProvider: Sendable {
    func knownHostsPath() throws -> String
}

enum KnownHostsPathProviderError: Error, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    case applicationSupportUnavailable

    var description: String { "known_hosts_path_unavailable" }
    var debugDescription: String { description }
}

struct ApplicationSupportKnownHostsPathProvider: KnownHostsPathProvider {
    func knownHostsPath() throws -> String {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw KnownHostsPathProviderError.applicationSupportUnavailable
        }
        return applicationSupport
            .appendingPathComponent("OrbitTerm", isDirectory: true)
            .appendingPathComponent("Security", isDirectory: true)
            .appendingPathComponent("known_hosts", isDirectory: false)
            .path
    }
}

struct KnownHostsTrustMaintenanceService {
    private let pathProvider: any KnownHostsPathProvider
    private let resultReader: OrbitCStringResultReader

    init(
        pathProvider: any KnownHostsPathProvider = ApplicationSupportKnownHostsPathProvider(),
        resultReader: OrbitCStringResultReader = .orbitCore
    ) {
        self.pathProvider = pathProvider
        self.resultReader = resultReader
    }

    /// Removes only the old key whose fingerprint is still exactly the value
    /// shown in the changed-key warning. This never trusts the replacement:
    /// reconnecting must produce a fresh unknown-key confirmation.
    func removeChangedTrust(_ blocked: HostKeyBlockedPayload) throws {
        guard blocked.reasonCode == .changed,
              blocked.canReplace,
              let previousFingerprint = blocked.previousFingerprintSHA256,
              !previousFingerprint.isEmpty else {
            throw CheckedFFIClientError.invalidInput
        }
        let path = try pathProvider.knownHostsPath()
        let pointer = blocked.host.withCString { host in
            blocked.keyAlgorithm.withCString { algorithm in
                previousFingerprint.withCString { fingerprint in
                    path.withCString { knownHostsPath in
                        orbit_known_hosts_remove_trusted_v1(
                            host,
                            blocked.port,
                            algorithm,
                            fingerprint,
                            knownHostsPath
                        )
                    }
                }
            }
        }
        let json = try resultReader.take(pointer)
        let envelope = try CheckedFFIWireDecoder.decode(
            CheckedFFIEnvelope<HostKeyTrustRemovedPayload>.self,
            from: Data(json.utf8)
        )
        if envelope.kind == .error, let error = envelope.error {
            throw CheckedFFIClientError.ffiErrorPayload(error)
        }
        try envelope.validateKind(.hostKeyTrustRemoved)
        guard let payload = envelope.data,
              payload.port == blocked.port,
              payload.keyAlgorithm == blocked.keyAlgorithm,
              payload.previousFingerprintSHA256 == previousFingerprint,
              payload.removedCount > 0 else {
            throw CheckedFFIClientError.protocolViolation
        }
    }
}
