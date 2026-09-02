import XCTest

final class ClipboardSecurityPolicyTests: XCTestCase {
    func testOrdinaryTextDoesNotScheduleAutomaticClear() {
        XCTAssertTrue(ClipboardContentKind.ordinaryText.canCopy)
        XCTAssertNil(ClipboardContentKind.ordinaryText.expiryNanoseconds)
    }

    func testTerminalAndFingerprintAreTimeBound() {
        XCTAssertTrue(ClipboardContentKind.terminalOutput.canCopy)
        XCTAssertTrue(ClipboardContentKind.hostKeyFingerprint.canCopy)
        XCTAssertNotNil(ClipboardContentKind.terminalOutput.expiryNanoseconds)
        XCTAssertNotNil(ClipboardContentKind.hostKeyFingerprint.expiryNanoseconds)
        XCTAssertTrue(ClipboardContentKind.terminalOutput.suppressesSystemPreview)
        XCTAssertFalse(ClipboardContentKind.terminalOutput.allowsCrossDeviceSharing)
    }

    func testCredentialsAndPrivateKeysAreRejected() {
        XCTAssertFalse(ClipboardContentKind.credential.canCopy)
        XCTAssertFalse(ClipboardContentKind.privateKey.canCopy)
        XCTAssertNil(ClipboardContentKind.credential.expiryNanoseconds)
        XCTAssertNil(ClipboardContentKind.privateKey.expiryNanoseconds)
    }

    func testSensitiveCoverIsShownOutsideActiveSceneOrDuringCapture() {
        XCTAssertFalse(
            SensitiveScreenVisibilityPolicy.shouldCover(
                isSceneActive: true,
                isScreenCaptured: false
            )
        )
        XCTAssertTrue(
            SensitiveScreenVisibilityPolicy.shouldCover(
                isSceneActive: false,
                isScreenCaptured: false
            )
        )
        XCTAssertTrue(
            SensitiveScreenVisibilityPolicy.shouldCover(
                isSceneActive: true,
                isScreenCaptured: true
            )
        )
    }
}
