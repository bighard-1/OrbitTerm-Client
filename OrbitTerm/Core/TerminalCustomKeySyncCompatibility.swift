import Foundation

/// Read-only reservation, not a payload validator or permission to publish.
enum TerminalCustomKeySyncCompatibility {
    enum Routing: Equatable { case unrelated, deferred, invalidAssetIdentity }

    static func routing(_ plaintext: Data, assetID: String?) -> Routing {
        guard let object = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              object["kind"] as? String == "terminal_custom_keys" else { return .unrelated }
        // Inspect no version or entries: future schemas must remain opaque.
        // Account-level envelopes must never borrow a server's deletion identity.
        return assetID == nil ? .deferred : .invalidAssetIdentity
    }

    enum RoutingError: Error { case deferred, invalidAssetIdentity }
}
