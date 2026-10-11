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

/// Fail-closed ownership rule for upgrading one legacy unscoped document.
/// The reservation stores only an opaque account namespace and remains in
/// place until the new scoped document and its credentials are both durable.
enum AccountMigrationReservationPolicy {
    static func canResume(
        migrationCompleted: Bool,
        reservedOwner: String?,
        requestingScope: String
    ) -> Bool {
        guard !migrationCompleted, !requestingScope.isEmpty else { return false }
        return reservedOwner == nil || reservedOwner == requestingScope
    }
}

/// A fresh store starts with an empty in-memory list. Flushing it before the
/// first account load or signed-out presentation would overwrite the
/// device-local asset cache with [].
enum AccountScopeSnapshotPolicy {
    static func shouldFlushBeforeScopeChange(previousScope: AccountScope?) -> Bool {
        previousScope != nil
    }
}

/// The independent macOS QA bundle must never read or mutate the production
/// app's shared Application Support files or legacy file-Keychain items.
/// Isolation needs both an explicit Debug build flag and the exact QA bundle.
enum MacQARuntimeIsolation {
    static func isAllowed(bundleIdentifier: String?, isolationRequested: Bool) -> Bool {
        isolationRequested && bundleIdentifier == "com.orbitterm.matrix.macos"
    }

    static var isEnabled: Bool {
        #if os(macOS) && DEBUG && ORBITTERM_MACOS_ISOLATED_QA
        return isAllowed(bundleIdentifier: Bundle.main.bundleIdentifier, isolationRequested: true)
        #else
        return false
        #endif
    }

    static var applicationDirectoryName: String {
        isEnabled ? "OrbitTerm-Mac-QA" : "OrbitTerm"
    }
}
