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

    func testDurableFailureEvidenceKeepsBlockedPrefixAndBoundedHTTPStatusOnly() {
        XCTAssertEqual(
            SyncQueueFailureEvidence.persistedError(
                diagnosticCode: "sync.requestRejected",
                disposition: .blocked,
                underlyingError: NetworkService.NetworkError.httpStatus(409, retryAfterSeconds: nil)
            ),
            "blocked:sync.requestRejected|http=409"
        )
        XCTAssertEqual(
            SyncQueueFailureEvidence.persistedError(
                diagnosticCode: "sync.serviceUnavailable",
                disposition: .automaticRetry,
                underlyingError: NetworkService.NetworkError.httpStatus(503, retryAfterSeconds: 120)
            ),
            "sync.serviceUnavailable|http=503"
        )
        XCTAssertEqual(
            SyncQueueFailureEvidence.persistedError(
                diagnosticCode: "sync.requestRejected",
                disposition: .blocked,
                underlyingError: NetworkService.NetworkError.requestTooLarge
            ),
            "blocked:sync.requestRejected|http=413"
        )
        XCTAssertEqual(
            SyncQueueFailureEvidence.persistedError(
                diagnosticCode: "sync.requestRejected",
                disposition: .blocked,
                underlyingError: NetworkService.NetworkError.unexpectedStatus(-1)
            ),
            "blocked:sync.requestRejected"
        )
        XCTAssertEqual(
            SyncQueueFailureEvidence.persistedError(
                diagnosticCode: "sync.requestRejected",
                disposition: .blocked,
                underlyingError: NetworkService.NetworkError.server("private-response-must-not-persist")
            ),
            "blocked:sync.requestRejected"
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

    func testBlockedDeleteRequiresSameAssetAndDominatingRemoteTombstone() {
        let assetID = UUID()
        let queuedClock = #"{"device-a":2,"device-b":1}"#
        let confirmed = ConfirmedRemoteTombstone(
            assetID: assetID,
            state: "deleted",
            vectorClock: #"{"device-a":3,"device-b":1,"device-c":5}"#,
            serverRevision: 17
        )
        XCTAssertTrue(SyncQueueTombstoneReconciliationPolicy.mayAcknowledge(
            queuedAssetID: assetID,
            queuedVectorClock: queuedClock,
            persistedError: SyncQueueTombstoneReconciliationPolicy.blockedConflictCode,
            remote: confirmed
        ))
        XCTAssertTrue(SyncQueueTombstoneReconciliationPolicy.mayAcknowledge(
            queuedAssetID: assetID,
            queuedVectorClock: queuedClock,
            persistedError: SyncQueueTombstoneReconciliationPolicy.blockedConflictCode,
            remote: ConfirmedRemoteTombstone(
                assetID: assetID,
                state: "purged",
                vectorClock: confirmed.vectorClock,
                serverRevision: confirmed.serverRevision
            )
        ))
    }

    func testBlockedDeleteIsNotAcknowledgedOnUnprovenOrCompetingState() {
        let assetID = UUID()
        let queuedClock = #"{"device-a":2,"device-b":1}"#
        let confirmed = ConfirmedRemoteTombstone(
            assetID: assetID,
            state: "deleted",
            vectorClock: #"{"device-a":2,"device-b":1}"#,
            serverRevision: 17
        )
        func accepts(
            _ remote: ConfirmedRemoteTombstone,
            queuedAssetID: UUID? = nil,
            queuedVectorClock: String? = nil,
            error: String? = SyncQueueTombstoneReconciliationPolicy.blockedConflictCode
        ) -> Bool {
            SyncQueueTombstoneReconciliationPolicy.mayAcknowledge(
                queuedAssetID: queuedAssetID ?? assetID,
                queuedVectorClock: queuedVectorClock ?? queuedClock,
                persistedError: error,
                remote: remote
            )
        }
        XCTAssertFalse(accepts(confirmed, error: nil))
        XCTAssertFalse(accepts(confirmed, error: "blocked:sync.requestRejected|http=403"))
        XCTAssertFalse(accepts(confirmed, queuedAssetID: UUID()))
        XCTAssertFalse(accepts(ConfirmedRemoteTombstone(
            assetID: UUID(), state: "deleted", vectorClock: confirmed.vectorClock, serverRevision: 17
        )))
        XCTAssertFalse(accepts(ConfirmedRemoteTombstone(
            assetID: assetID, state: "active", vectorClock: confirmed.vectorClock, serverRevision: 17
        )))
        XCTAssertFalse(accepts(ConfirmedRemoteTombstone(
            assetID: assetID, state: "deleted", vectorClock: confirmed.vectorClock, serverRevision: 0
        )))
        for clock in [
            #"{"device-a":1,"device-b":1}"#,
            #"{"device-a":2}"#,
            #"{"device-a":2,"device-b":-1}"#,
            #"{}"#,
            "invalid-json"
        ] {
            XCTAssertFalse(accepts(ConfirmedRemoteTombstone(
                assetID: assetID, state: "deleted", vectorClock: clock, serverRevision: 17
            )), "Unproven vector clock must retain blocked delete: \(clock)")
        }
        for clock in [#"{}"#, #"{"device-a":2,"device-b":-1}"#, "invalid-json"] {
            XCTAssertFalse(accepts(confirmed, queuedVectorClock: clock))
        }
    }
}
