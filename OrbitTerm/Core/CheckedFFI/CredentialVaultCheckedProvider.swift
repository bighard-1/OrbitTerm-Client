import Foundation

struct CredentialVaultCheckedProvider: CheckedCredentialProvider, @unchecked Sendable {
    func credentials(for reference: CredentialAccessReference) async throws -> CheckedCredentials {
        let credentials: ServerCredentials
        do {
            guard let stored = try CredentialVault.shared.read(for: reference.id),
                  !stored.isEmpty else {
                throw CheckedFFIClientError.credentialUnavailable
            }
            credentials = stored
        } catch let error as CheckedFFIClientError {
            throw error
        } catch {
            throw CheckedFFIClientError.credentialStorageFailed
        }
        return CheckedCredentials(
            password: credentials.password,
            privateKey: credentials.privateKeyContent,
            privateKeyPassphrase: credentials.privateKeyPassphrase,
            allowPasswordFallback: reference.allowPasswordFallback
        )
    }
}
