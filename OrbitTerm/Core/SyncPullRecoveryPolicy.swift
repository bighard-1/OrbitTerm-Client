import Foundation

/// Decides when a device with no local asset cache needs an inventory pull.
/// Incremental sync is authoritative for deltas, but an empty delta cannot
/// reconstruct an empty cache when the server has pre-existing legacy assets.
enum SyncPullRecoveryPolicy {
    static func shouldPerformFullPull(
        localAssetCount: Int,
        incrementalResponseHadChanges: Bool
    ) -> Bool {
        localAssetCount == 0 && !incrementalResponseHadChanges
    }

    /// A confirmed empty inventory must never silently overwrite local assets.
    /// Instead, an explicit user action may publish the local inventory.
    static func localAssetIDsPendingExplicitPublication(
        localAssetIDs: Set<String>,
        cloudKnownAssetIDs: Set<String>
    ) -> Set<String> {
        localAssetIDs.subtracting(cloudKnownAssetIDs)
    }

    /// A manual reconciliation may only claim success after the same account's
    /// follow-up inventory contains the local asset IDs it attempted to publish.
    /// The function deliberately works on IDs only: it never inspects names,
    /// credentials, or user-visible status text.
    static func unverifiedPublishedAssetIDs(
        attemptedLocalAssetIDs: Set<String>,
        cloudKnownAssetIDs: Set<String>
    ) -> Set<String> {
        attemptedLocalAssetIDs.subtracting(cloudKnownAssetIDs)
    }

    static func remoteAssetsRequireMasterPasswordRecovery(
        remoteAssetCount: Int,
        decodedRemoteAssetCount: Int
    ) -> Bool {
        remoteAssetCount > 0 && decodedRemoteAssetCount == 0
    }
}
