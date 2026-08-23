import Foundation

/// A single SSH hop used to reach an otherwise unreachable SSH asset.
///
/// The configuration deliberately contains only connection metadata. Its
/// credential material is kept under `credentialID` in `CredentialVault`,
/// separate from the destination asset credential.
struct JumpHostConfiguration: Codable, Hashable, Sendable {
    var host: String
    var port: Int
    var username: String
    var authMethod: ServerAuthMethod
    var allowPasswordFallback: Bool
    var credentialID: UUID

    init(
        host: String,
        port: Int = 22,
        username: String,
        authMethod: ServerAuthMethod,
        allowPasswordFallback: Bool = true,
        credentialID: UUID = UUID()
    ) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authMethod = authMethod
        self.allowPasswordFallback = allowPasswordFallback
        self.credentialID = credentialID
    }

    var endpointText: String {
        "\(host):\(port)"
    }

    /// Validation stays presentation-independent so the same invariant can be
    /// shared by macOS and iOS forms before a checked connection is started.
    var isValid: Bool {
        !host.isEmpty && !username.isEmpty && (1 ... 65_535).contains(port)
    }
}

/// The encrypted cross-device representation of a jump host. This is embedded
/// only in the already encrypted portable asset payload; it is never stored in
/// the ordinary `ServerEntry` metadata cache.
struct PortableJumpHostConfiguration: Codable, Equatable {
    let credentialID: String
    let host: String
    let port: Int
    let username: String
    let authMethod: String
    let allowPasswordFallback: Bool
    let password: String
    let privateKeyContent: String
    let privateKeyPassphrase: String

    init(
        configuration: JumpHostConfiguration,
        credentials: ServerCredentials?
    ) {
        credentialID = configuration.credentialID.uuidString
        host = configuration.host
        port = configuration.port
        username = configuration.username
        authMethod = configuration.authMethod.rawValue
        allowPasswordFallback = configuration.allowPasswordFallback
        password = credentials?.password ?? ""
        privateKeyContent = credentials?.privateKeyContent ?? ""
        privateKeyPassphrase = credentials?.privateKeyPassphrase ?? ""
    }

    func makeConfiguration() -> JumpHostConfiguration? {
        guard let credentialID = UUID(uuidString: credentialID),
              let authMethod = ServerAuthMethod(rawValue: authMethod) else {
            return nil
        }
        let configuration = JumpHostConfiguration(
            host: host,
            port: port,
            username: username,
            authMethod: authMethod,
            allowPasswordFallback: allowPasswordFallback,
            credentialID: credentialID
        )
        return configuration.isValid ? configuration : nil
    }

    var credentials: ServerCredentials {
        ServerCredentials(
            password: password,
            privateKeyContent: privateKeyContent,
            privateKeyPassphrase: privateKeyPassphrase
        )
    }

    /// A portable hop that cannot authenticate must never be silently reduced
    /// to a direct connection while being restored from encrypted sync data.
    var hasAuthenticationMaterial: Bool {
        !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
