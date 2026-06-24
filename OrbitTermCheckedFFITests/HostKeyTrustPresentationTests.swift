import XCTest

final class HostKeyTrustPresentationTests: XCTestCase {
    func testUnknownPresentationContainsIdentityAndOnlySafeActions() {
        let presentation = HostKeyChallengePresentation(payload: challenge())

        XCTAssertEqual(presentation.host, "fixture.example")
        XCTAssertEqual(presentation.port, 2222)
        XCTAssertEqual(presentation.algorithm, "ssh-ed25519")
        XCTAssertEqual(presentation.fingerprint, "SHA256:fixture")
        XCTAssertEqual(presentation.actions, [.cancel, .trustThisHost])
    }

    func testExpiredChallengeCannotBeTrusted() {
        let presentation = HostKeyChallengePresentation(
            payload: challenge(),
            nowUnix: 2_000_000_001
        )

        XCTAssertTrue(presentation.isExpired)
        XCTAssertEqual(presentation.actions, [.cancel])
    }

    func testChangedPresentationHasCopyAndCloseButNoTrustAction() {
        let presentation = HostKeyBlockedPresentation(payload: block(.changed))

        XCTAssertEqual(presentation.severity, .changed)
        XCTAssertEqual(presentation.previousFingerprint, "SHA256:previous")
        XCTAssertEqual(presentation.actions, [.close, .copyFingerprints])
        XCTAssertFalse(presentation.actions.contains(.trustThisHost))
    }

    func testRevokedPresentationCannotContinue() {
        let presentation = HostKeyBlockedPresentation(payload: block(.revoked))

        XCTAssertEqual(presentation.severity, .revoked)
        XCTAssertNil(presentation.previousFingerprint)
        XCTAssertEqual(presentation.actions, [.close, .copyFingerprints])
    }

    func testSaveErrorOffersRetryAndCancelWithoutPath() {
        let presentation = HostKeySaveErrorPresentation()
        let rendered = "\(presentation.title) \(presentation.message)"

        XCTAssertEqual(presentation.actions, [.retrySave, .cancel])
        XCTAssertFalse(rendered.contains("known_hosts"))
        XCTAssertFalse(rendered.contains("/Users/"))
    }

    func testCredentialReferenceAndConnectInputDescriptionsAreRedacted() {
        let reference = CredentialAccessReference()
        let input = CheckedConnectInput(
            host: "fixture.example",
            port: 22,
            username: "fixture-user",
            credentialReference: reference
        )

        XCTAssertFalse(String(reflecting: input).contains(reference.id.uuidString))
        XCTAssertTrue(String(reflecting: input).contains("[REDACTED]"))
    }

    private func challenge() -> HostKeyChallengePayload {
        HostKeyChallengePayload(
            challengeID: "challenge-1",
            requestID: try! HostKeyRequestID("request-1"),
            host: "fixture.example",
            normalizedHost: "fixture.example",
            port: 2222,
            lookupToken: "[fixture.example]:2222",
            keyAlgorithm: "ssh-ed25519",
            fingerprintSHA256: "SHA256:fixture",
            reasonCode: .unknownHost,
            knownState: .unknownHost,
            canTrust: true,
            canReplace: false,
            expiresAtUnix: 2_000_000_000,
            reusedExistingChallenge: false,
            relatedRequestCount: 1
        )
    }

    private func block(_ reason: HostKeyBlockReasonCode) -> HostKeyBlockedPayload {
        HostKeyBlockedPayload(
            host: "fixture.example",
            normalizedHost: "fixture.example",
            port: 2222,
            lookupToken: "[fixture.example]:2222",
            keyAlgorithm: "ssh-ed25519",
            presentedFingerprintSHA256: "SHA256:presented",
            previousFingerprintSHA256: reason == .changed ? "SHA256:previous" : nil,
            reasonCode: reason,
            knownState: reason == .changed ? .changed : .revoked,
            canTrust: false,
            canReplace: reason == .changed,
            messageKey: reason == .changed ? "host_key.changed" : "host_key.revoked"
        )
    }
}
