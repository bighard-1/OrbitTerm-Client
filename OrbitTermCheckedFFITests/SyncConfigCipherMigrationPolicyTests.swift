import XCTest

final class SyncConfigCipherMigrationPolicyTests: XCTestCase {
    func testExplicitFullSyncPreflightsEvenWhenLocalCompletionMarkerExists() {
        XCTAssertTrue(
            SyncConfigCipherMigrationPolicy.shouldAttempt(
                hasCompletedMarker: true,
                isExplicitFullSync: true,
                cooldownAllowsRetry: false
            )
        )
    }

    func testCompletedMarkerSuppressesBackgroundPreflight() {
        XCTAssertFalse(
            SyncConfigCipherMigrationPolicy.shouldAttempt(
                hasCompletedMarker: true,
                isExplicitFullSync: false,
                cooldownAllowsRetry: true
            )
        )
    }

    func testMissingMarkerRespectsBackgroundCooldown() {
        XCTAssertFalse(
            SyncConfigCipherMigrationPolicy.shouldAttempt(
                hasCompletedMarker: false,
                isExplicitFullSync: false,
                cooldownAllowsRetry: false
            )
        )
        XCTAssertTrue(
            SyncConfigCipherMigrationPolicy.shouldAttempt(
                hasCompletedMarker: false,
                isExplicitFullSync: false,
                cooldownAllowsRetry: true
            )
        )
    }

    func testMigrationPresentationNeverUsesServerErrorText() {
        XCTAssertEqual(
            SyncConfigCipherMigrationPolicy.userMessage(for: .migrated(9)),
            "加密格式迁移完成：9 项"
        )
        XCTAssertEqual(
            SyncConfigCipherMigrationPolicy.userMessage(for: .alreadyVerified(9)),
            "加密格式已验证：9 项"
        )
        XCTAssertEqual(
            SyncConfigCipherMigrationPolicy.userMessage(for: .pendingRetry("SYNC_HTTP_CONFLICT")),
            "加密格式迁移待重试（SYNC_HTTP_CONFLICT）"
        )
    }
}
