import XCTest

final class OperationRecoveryPresentationTests: XCTestCase {
    func testCancelledSyncDoesNotMasqueradeAsNetworkFailure() {
        let presentation = OperationRecoveryMapper.sync(CancellationError())
        XCTAssertEqual(presentation.code, .operationCancelled)
        XCTAssertFalse(presentation.actions.contains(.retry))
    }

    func testURLCancellationDoesNotMasqueradeAsNetworkFailure() {
        let presentation = OperationRecoveryMapper.sync(URLError(.cancelled))
        XCTAssertEqual(presentation.code, .operationCancelled)
    }

    func testLoginThrottleUsesBoundedProgressiveCooldown() {
        XCTAssertEqual(LoginCooldownPolicy.seconds(failureCount: 1), 0)
        XCTAssertEqual(LoginCooldownPolicy.seconds(failureCount: 3), 5)
        XCTAssertEqual(LoginCooldownPolicy.seconds(failureCount: 5), 30)
        XCTAssertEqual(LoginCooldownPolicy.seconds(failureCount: 7), 120)
        XCTAssertEqual(LoginCooldownPolicy.seconds(failureCount: 99), 300)
    }
    func testSyncUnauthorizedOffersReauthenticationWithoutRawMessage() {
        let value = OperationRecoveryMapper.sync(.authenticationExpired)

        XCTAssertEqual(value.domain, .sync)
        XCTAssertEqual(value.code, .authenticationExpired)
        XCTAssertEqual(value.actions, [.reauthenticate])
        XCTAssertEqual(value.diagnosticCode, "sync.authenticationExpired")
        XCTAssertFalse(value.message.contains("token"))
        XCTAssertFalse(value.message.contains("@"))
    }

    func testCheckedServicesPreserveRecoverySemanticsByTypedFailure() {
        XCTAssertEqual(
            OperationRecoveryMapper.sftp(.requiresVerifiedSession).actions,
            [.reconnect, .dismiss]
        )
        XCTAssertEqual(
            OperationRecoveryMapper.docker(.sessionClosed).code,
            .sessionClosed
        )
        XCTAssertEqual(
            OperationRecoveryMapper.monitor(.checkedMonitorSnapshotFailed(nil)).code,
            .networkUnavailable
        )
    }

    func testConnectionBlockNeverDowngradesToGenericRetry() {
        let value = OperationRecoveryMapper.connection(.blocked(makeBlockedPayload()))

        XCTAssertEqual(value?.code, .hostIdentityBlocked)
        XCTAssertEqual(value?.severity, .danger)
        XCTAssertEqual(value?.actions, [.reviewHostKey, .dismiss])
        XCTAssertFalse(value?.actions.contains(.retry) ?? true)
        XCTAssertFalse(value?.message.contains("sensitive.example.test") ?? true)
        XCTAssertFalse(value?.message.contains("SHA256:") ?? true)
    }

    func testMasterPasswordRecoveryIsTypedAndRedacted() {
        let value = OperationRecoveryMapper.syncMasterPasswordMismatch()

        XCTAssertEqual(value.code, .masterPasswordMismatch)
        XCTAssertTrue(value.actions.contains(.unlock))
        XCTAssertTrue(value.actions.contains(.retry))
        XCTAssertEqual(value.diagnosticCode, "sync.masterPasswordMismatch")
    }

    private func makeBlockedPayload() -> HostKeyBlockedPayload {
        HostKeyBlockedPayload(
            host: "sensitive.example.test",
            normalizedHost: "sensitive.example.test",
            port: 22,
            lookupToken: "[sensitive.example.test]:22",
            keyAlgorithm: "ssh-ed25519",
            presentedFingerprintSHA256: "SHA256:sensitive",
            previousFingerprintSHA256: "SHA256:previous",
            reasonCode: .changed,
            knownState: .changed,
            canTrust: false,
            canReplace: false,
            messageKey: "host_key.changed"
        )
    }
}
