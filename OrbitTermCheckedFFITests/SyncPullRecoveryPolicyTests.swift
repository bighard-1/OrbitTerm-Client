import XCTest

final class SyncPullRecoveryPolicyTests: XCTestCase {
    func testEmptyLocalCacheAndEmptyIncrementalPageRequestsFullPull() {
        XCTAssertTrue(
            SyncPullRecoveryPolicy.shouldPerformFullPull(
                localAssetCount: 0,
                incrementalResponseHadChanges: false
            )
        )
    }

    func testExistingLocalCacheDoesNotRequestFullPullForEmptyIncrementalPage() {
        XCTAssertFalse(
            SyncPullRecoveryPolicy.shouldPerformFullPull(
                localAssetCount: 1,
                incrementalResponseHadChanges: false
            )
        )
    }

    func testAnyIncrementalChangeAvoidsRedundantFullPullForEmptyCache() {
        XCTAssertFalse(
            SyncPullRecoveryPolicy.shouldPerformFullPull(
                localAssetCount: 0,
                incrementalResponseHadChanges: true
            )
        )
    }

    func testCloudMissingLocalAssetsRequireExplicitPublication() {
        XCTAssertEqual(
            SyncPullRecoveryPolicy.localAssetIDsPendingExplicitPublication(
                localAssetIDs: ["a", "b", "c"],
                cloudKnownAssetIDs: ["a"]
            ),
            ["b", "c"]
        )
    }

    func testCloudKnownAssetsAndEmptyLocalCacheDoNotOfferPublicationRecovery() {
        XCTAssertEqual(
            SyncPullRecoveryPolicy.localAssetIDsPendingExplicitPublication(
                localAssetIDs: ["a"],
                cloudKnownAssetIDs: ["a"]
            ),
            []
        )
        XCTAssertEqual(
            SyncPullRecoveryPolicy.localAssetIDsPendingExplicitPublication(
                localAssetIDs: [],
                cloudKnownAssetIDs: ["a"]
            ),
            []
        )
    }

    func testSnippetOnlyCloudStillOffersExplicitLocalAssetPublication() {
        XCTAssertEqual(
            SyncPullRecoveryPolicy.localAssetIDsPendingExplicitPublication(
                localAssetIDs: ["local-a", "local-b"],
                cloudKnownAssetIDs: []
            ),
            ["local-a", "local-b"]
        )
    }

    func testUndecryptableRemoteAssetsRequestMasterPasswordRecoveryInsteadOfPublication() {
        XCTAssertTrue(
            SyncPullRecoveryPolicy.remoteAssetsRequireMasterPasswordRecovery(
                remoteAssetCount: 2,
                decodedRemoteAssetCount: 0
            )
        )
        XCTAssertFalse(
            SyncPullRecoveryPolicy.remoteAssetsRequireMasterPasswordRecovery(
                remoteAssetCount: 2,
                decodedRemoteAssetCount: 1
            )
        )
    }

    func testVerificationKeepsOnlyPublishedAssetIDsMissingFromFollowUpInventory() {
        XCTAssertEqual(
            SyncPullRecoveryPolicy.unverifiedPublishedAssetIDs(
                attemptedLocalAssetIDs: ["a", "b", "c"],
                cloudKnownAssetIDs: ["a", "c", "remote-tombstone"]
            ),
            ["b"]
        )
    }
}
