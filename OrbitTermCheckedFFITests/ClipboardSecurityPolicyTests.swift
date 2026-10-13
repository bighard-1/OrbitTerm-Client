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
        XCTAssertFalse(
            SensitiveScreenVisibilityPolicy.shouldCover(
                isSceneActive: true,
                isScreenCaptured: true,
                allowsTemporaryCapture: true
            )
        )
        XCTAssertTrue(
            SensitiveScreenVisibilityPolicy.shouldCover(
                isSceneActive: false,
                isScreenCaptured: true,
                allowsTemporaryCapture: true
            )
        )
    }

    func testTemporaryCaptureAuthorizationIsShortLivedAndBoundToUnlockedAccount() {
        let now = Date(timeIntervalSince1970: 1_000)
        let expiry = now.addingTimeInterval(TemporaryCaptureAuthorizationPolicy.lifetime)
        func allows(account: String = "qa", time: Date = now,
                    authenticated: Bool = true, unlocked: Bool = true,
                    mustChange: Bool = false, active: Bool = true) -> Bool {
            TemporaryCaptureAuthorizationPolicy.allows(
                authorizedAccount: "qa",
                currentAccount: account,
                expiresAt: expiry,
                now: time,
                isAuthenticated: authenticated,
                isUnlocked: unlocked,
                mustChangePassword: mustChange,
                isSceneActive: active
            )
        }
        XCTAssertEqual(TemporaryCaptureAuthorizationPolicy.lifetime, 180)
        XCTAssertTrue(allows())
        XCTAssertFalse(allows(account: "other"))
        XCTAssertFalse(allows(time: expiry))
        XCTAssertFalse(allows(authenticated: false))
        XCTAssertFalse(allows(unlocked: false))
        XCTAssertFalse(allows(mustChange: true))
        XCTAssertFalse(allows(active: false))
        XCTAssertFalse(TemporaryCaptureAuthorizationPolicy.allows(
            authorizedAccount: nil,
            currentAccount: "qa",
            expiresAt: expiry,
            now: now,
            isAuthenticated: true,
            isUnlocked: true,
            mustChangePassword: false,
            isSceneActive: true
        ))
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
