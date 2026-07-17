import Foundation

/// Defines where a saved command may be offered. This is an eligibility rule
/// for the client UI; it does not grant access to an asset or alter SSH policy.
struct SnippetAssetScope: Codable, Hashable, Sendable {
    enum Mode: String, Codable, Sendable {
        case allAssets
        case selectedAssets
    }

    let mode: Mode
    let assetIDs: Set<UUID>

    static let allAssets = SnippetAssetScope(mode: .allAssets, assetIDs: [])

    static func selectedAssets(_ assetIDs: Set<UUID>) -> SnippetAssetScope {
        guard !assetIDs.isEmpty else { return .allAssets }
        return SnippetAssetScope(mode: .selectedAssets, assetIDs: assetIDs)
    }

    func allows(assetID: UUID) -> Bool {
        mode == .allAssets || assetIDs.contains(assetID)
    }

    var isRestricted: Bool {
        mode == .selectedAssets
    }

    private init(mode: Mode, assetIDs: Set<UUID>) {
        self.mode = mode
        self.assetIDs = assetIDs
    }
}
