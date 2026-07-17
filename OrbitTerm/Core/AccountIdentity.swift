import Foundation

/// Shared account-input canonicalization. The server applies the equivalent
/// rule and persists the canonical value, so all Apple clients send the same
/// account identifier for the same email-style username.
enum AccountIdentity {
    static func canonicalUsername(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
