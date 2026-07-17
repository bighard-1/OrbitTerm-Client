import CryptoKit
import Foundation

/// Stable, privacy-preserving namespace for data that belongs to one signed-in account.
///
/// The canonical identifier is never used as part of a UserDefaults key or file name.
/// Keeping this conversion in one place prevents individual stores from inventing their
/// own account scoping rules.
struct AccountScope: Hashable, Sendable {
    let canonicalUsername: String

    init?(username: String) {
        let canonical = AccountIdentity.canonicalUsername(username)
        guard !canonical.isEmpty else { return nil }
        canonicalUsername = canonical
    }

    /// Opaque namespace suitable for local storage keys and file names.
    var storageIdentifier: String {
        let digest = SHA256.hash(data: Data(canonicalUsername.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func storageKey(_ namespace: String) -> String {
        "\(namespace).\(storageIdentifier)"
    }

    func databaseFileName(_ baseName: String, pathExtension: String) -> String {
        "\(baseName)-\(storageIdentifier).\(pathExtension)"
    }
}
