import XCTest

final class SyncQueueRecoveryPolicyTests: XCTestCase {
    func testTemporaryTransportFailuresRemainRetryable() {
        XCTAssertEqual(
            SyncQueueRecoveryPolicy.disposition(for: "sync.networkUnavailable"),
            .automaticRetry
        )
        XCTAssertEqual(
            SyncQueueRecoveryPolicy.disposition(for: "sync.timedOut"),
            .automaticRetry
        )
        XCTAssertEqual(
            SyncQueueRecoveryPolicy.disposition(
                for: "sync.serviceUnavailable",
                attemptCount: SyncQueueRecoveryPolicy.maximumServiceUnavailableAttempts
            ),
            .automaticRetry
        )
        XCTAssertEqual(
            SyncQueueRecoveryPolicy.disposition(
                for: "sync.serviceUnavailable",
                attemptCount: SyncQueueRecoveryPolicy.maximumServiceUnavailableAttempts + 1
            ),
            .blocked
        )
    }

    func testAuthenticationWaitsForFreshCredentials() {
        XCTAssertEqual(
            SyncQueueRecoveryPolicy.disposition(for: "sync.authenticationExpired"),
            .waitForAuthentication
        )
    }

    func testConfigurationProtocolAndUnknownFailuresAreBlocked() {
        for code in ["sync.serviceConfigurationInvalid", "sync.requestRejected", "sync.protocolViolation", "sync.unknown"] {
            XCTAssertEqual(SyncQueueRecoveryPolicy.disposition(for: code), .blocked)
            XCTAssertEqual(
                SyncQueueRecoveryPolicy.persistedError(diagnosticCode: code, disposition: .blocked),
                "blocked:\(code)"
            )
        }
    }

    func testServerDelayCanExtendButNeverShortenLocalBackoff() {
        XCTAssertEqual(
            SyncQueueRecoveryPolicy.effectiveRetryDelay(defaultBackoff: 30, serverSuggested: 120),
            120
        )
        XCTAssertEqual(
            SyncQueueRecoveryPolicy.effectiveRetryDelay(defaultBackoff: 30, serverSuggested: 5),
            30
        )
        XCTAssertEqual(
            SyncQueueRecoveryPolicy.effectiveRetryDelay(defaultBackoff: 30, serverSuggested: nil),
            30
        )
    }

    func testRetryClockRejectsForwardAndBackwardWallClockJumps() {
        let forward = RetryClockGuard(toleratedWallClockDrift: 2)
        XCTAssertEqual(
            forward.trustedNow(wallClock: Date(timeIntervalSince1970: 1_000), systemUptime: 100),
            Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(
            forward.trustedNow(wallClock: Date(timeIntervalSince1970: 4_605), systemUptime: 105),
            Date(timeIntervalSince1970: 1_005)
        )

        let backward = RetryClockGuard(toleratedWallClockDrift: 2)
        _ = backward.trustedNow(wallClock: Date(timeIntervalSince1970: 2_000), systemUptime: 200)
        XCTAssertEqual(
            backward.trustedNow(wallClock: Date(timeIntervalSince1970: 1_000), systemUptime: 210),
            Date(timeIntervalSince1970: 2_010)
        )
    }

    func testRetryClockAcceptsOrdinaryDriftAndResetsForNewUptimeEpoch() {
        let clock = RetryClockGuard(toleratedWallClockDrift: 2)
        _ = clock.trustedNow(wallClock: Date(timeIntervalSince1970: 1_000), systemUptime: 100)
        XCTAssertEqual(
            clock.trustedNow(wallClock: Date(timeIntervalSince1970: 1_011), systemUptime: 110),
            Date(timeIntervalSince1970: 1_011)
        )
        XCTAssertEqual(
            clock.trustedNow(wallClock: Date(timeIntervalSince1970: 3_000), systemUptime: 5),
            Date(timeIntervalSince1970: 3_000)
        )
    }

    func testAccountReplacementLockAndSignOutInvalidateOldDelivery() {
        XCTAssertFalse(
            SyncQueueAccountTransitionPolicy.invalidatesCurrentDelivery(previous: "account-a", next: "account-a")
        )
        XCTAssertTrue(
            SyncQueueAccountTransitionPolicy.invalidatesCurrentDelivery(previous: "account-a", next: "account-b")
        )
        XCTAssertTrue(
            SyncQueueAccountTransitionPolicy.invalidatesCurrentDelivery(previous: "account-a", next: nil)
        )
        XCTAssertTrue(
            SyncQueueAccountTransitionPolicy.invalidatesCurrentDelivery(previous: nil, next: "account-a")
        )
    }
}
