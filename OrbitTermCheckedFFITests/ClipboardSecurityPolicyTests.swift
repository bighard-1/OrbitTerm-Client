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

    func testAnyReportedCaptureSignalRequiresProtection() {
        XCTAssertFalse(SensitiveCaptureSignalPolicy.isCaptured(
            swiftUIScene: false, uiKitScene: false, screen: false, qaBypass: false
        ))
        XCTAssertTrue(SensitiveCaptureSignalPolicy.isCaptured(
            swiftUIScene: true, uiKitScene: false, screen: false, qaBypass: false
        ))
        XCTAssertTrue(SensitiveCaptureSignalPolicy.isCaptured(
            swiftUIScene: false, uiKitScene: true, screen: false, qaBypass: false
        ))
        XCTAssertTrue(SensitiveCaptureSignalPolicy.isCaptured(
            swiftUIScene: false, uiKitScene: false, screen: true, qaBypass: false
        ))
        XCTAssertFalse(SensitiveCaptureSignalPolicy.isCaptured(
            swiftUIScene: true, uiKitScene: true, screen: true, qaBypass: true
        ))
    }
}
