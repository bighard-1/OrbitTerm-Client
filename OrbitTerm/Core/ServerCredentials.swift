import Foundation

/// Sensitive credential values kept separately from ordinary server metadata.
/// Persistence remains the responsibility of `CredentialVault`.
struct ServerCredentials: Codable, Equatable {
    var password: String
    var privateKeyContent: String
    var privateKeyPassphrase: String

    var isEmpty: Bool {
        password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            privateKeyPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(password: String = "", privateKeyContent: String = "", privateKeyPassphrase: String = "") {
        self.password = password
        self.privateKeyContent = privateKeyContent
        self.privateKeyPassphrase = privateKeyPassphrase
    }
}
