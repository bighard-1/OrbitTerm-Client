import Foundation

struct CredentialVaultCheckedProvider: CheckedCredentialProvider, @unchecked Sendable {
    func credentials(for reference: CredentialAccessReference) async throws -> CheckedCredentials {
        guard let credentials = try CredentialVault.shared.read(for: reference.id),
              !credentials.isEmpty else {
            throw CheckedFFIClientError.invalidInput
        }
        return CheckedCredentials(
            password: credentials.password,
            privateKey: credentials.privateKeyContent,
            privateKeyPassphrase: credentials.privateKeyPassphrase,
            allowPasswordFallback: reference.allowPasswordFallback
        )
    }
}
