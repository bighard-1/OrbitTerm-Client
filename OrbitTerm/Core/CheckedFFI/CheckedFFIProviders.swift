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
