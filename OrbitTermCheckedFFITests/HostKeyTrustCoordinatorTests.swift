import Foundation
import XCTest

@MainActor
final class HostKeyTrustCoordinatorTests: XCTestCase {
    func testDirectConnectSucceeds() async {
        let client = ScriptedCheckedFFIClient(connect: [.init(.connected)])
        let coordinator = HostKeyTrustCoordinator(client: client)

        let flowID = await coordinator.begin(input: input())

        guard case let .connected(actualFlow, sessionID) = coordinator.state else {
            return XCTFail("Expected connected state")
        }
        XCTAssertEqual(actualFlow, flowID)
        XCTAssertEqual(sessionID.decimalString, "72057594037927936")
    }

    func testSecondFactorUsesTransientCodeOnlyOnReconnect() async {
        let client = ScriptedCheckedFFIClient(connect: [
            .init(.error("ssh_second_factor_required")), .init(.connected),
        ])
        let coordinator = HostKeyTrustCoordinator(client: client)
        let flow = await coordinator.begin(input: input())
        guard case let .awaitingSecondFactor(actualFlow, forJump) = coordinator.state else {
            return XCTFail("Expected second-factor prompt")
        }
        XCTAssertEqual(actualFlow, flow)
        XCTAssertFalse(forJump)
        await coordinator.submitSecondFactor("123456")
        guard case .connected = coordinator.state else {
            return XCTFail("Expected verified session after code")
        }
        let scopes = await client.connectCodeScopes
        XCTAssertEqual(scopes.count, 2)
        XCTAssertFalse(scopes[0].target)
        XCTAssertFalse(scopes[0].jump)
        XCTAssertTrue(scopes[1].target)
        XCTAssertFalse(scopes[1].jump)
        XCTAssertFalse(input().withOneTimeCode("123456", forJump: false).description.contains("123456"))
    }

    func testSecondFactorCancelNeverReconnects() async {
        let client = ScriptedCheckedFFIClient(connect: [.init(.error("ssh_second_factor_required"))])
        let coordinator = HostKeyTrustCoordinator(client: client)
        let flow = await coordinator.begin(input: input())
        coordinator.cancel()
        await coordinator.submitSecondFactor("123456")
        XCTAssertEqual(coordinator.state, .cancelled(flow))
        let connectCount = await client.connectRequestIDs.count
        XCTAssertEqual(connectCount, 1)
    }

    func testJumpAndDestinationSecondFactorsAreScopedAndRetainedOnlyForFlow() async {
        let client = ScriptedCheckedFFIClient(connect: [
            .init(.secondFactor(forJump: true)),
            .init(.secondFactor(forJump: false)),
            .init(.connected),
        ])
        let coordinator = HostKeyTrustCoordinator(client: client)
        _ = await coordinator.begin(input: input())
        guard case .awaitingSecondFactor(_, true) = coordinator.state else {
            return XCTFail("Expected jump verification prompt")
        }
        await coordinator.submitSecondFactor("jump-code")
        guard case .awaitingSecondFactor(_, false) = coordinator.state else {
            return XCTFail("Expected destination verification prompt")
        }
        await coordinator.submitSecondFactor("target-code")
        guard case .connected = coordinator.state else {
            return XCTFail("Expected verified session")
        }
        let scopes = await client.connectCodeScopes
        XCTAssertEqual(scopes.map(\.target), [false, false, true])
        XCTAssertEqual(scopes.map(\.jump), [false, true, true])
    }

    func testRepeatedChallengeForSameHopFailsInsteadOfReprompting() async {
        let client = ScriptedCheckedFFIClient(connect: [
            .init(.secondFactor(forJump: false)),
            .init(.secondFactor(forJump: false)),
        ])
        let coordinator = HostKeyTrustCoordinator(client: client)
        _ = await coordinator.begin(input: input())
        await coordinator.submitSecondFactor("wrong-code")
        guard case let .failed(_, failure) = coordinator.state,
              case let .authentication(_, submittedSecondFactor) = failure else {
            return XCTFail("Repeated verification request must fail")
        }
        XCTAssertTrue(submittedSecondFactor)
        let recovery = OperationRecoveryMapper.connection(failure)
        XCTAssertTrue(recovery.message.contains("再次要求验证码"))
        XCTAssertFalse(recovery.message.contains("wrong-code"))
        let count = await client.connectRequestIDs.count
        XCTAssertEqual(count, 2)
    }

    func testAuthFailureAfterSecondFactorExplainsPossibilitiesWithoutLeakingCode() async {
        let client = ScriptedCheckedFFIClient(connect: [
            .init(.secondFactor(forJump: false)),
            .init(.error("ssh_auth_failed")),
        ])
        let coordinator = HostKeyTrustCoordinator(client: client)
        _ = await coordinator.begin(input: input())
        await coordinator.submitSecondFactor("test-code-not-for-output")

        guard case let .failed(_, failure) = coordinator.state,
              case let .authentication(_, submittedSecondFactor) = failure else {
            return XCTFail("Expected authentication failure after submitted code")
        }
        XCTAssertTrue(submittedSecondFactor)
        let recovery = OperationRecoveryMapper.connection(failure)
        XCTAssertTrue(recovery.message.contains("可能错误或过期"))
        XCTAssertTrue(recovery.message.contains("其他凭据或认证策略"))
        XCTAssertFalse(recovery.message.contains("test-code-not-for-output"))
    }

    func testAuthFailureAfterJumpSecondFactorKeepsTheSameSafeGuidance() async {
        let client = ScriptedCheckedFFIClient(connect: [
            .init(.secondFactor(forJump: true)),
            .init(.error("ssh_auth_failed")),
        ])
        let coordinator = HostKeyTrustCoordinator(client: client)
        _ = await coordinator.begin(input: input())
        await coordinator.submitSecondFactor("jump-code-not-for-output")

        guard case let .failed(_, failure) = coordinator.state,
              case let .authentication(_, submittedSecondFactor) = failure else {
            return XCTFail("Expected authentication failure after jump code")
        }
        XCTAssertTrue(submittedSecondFactor)
        let recovery = OperationRecoveryMapper.connection(failure)
        XCTAssertTrue(recovery.message.contains("可能错误或过期"))
        XCTAssertFalse(recovery.message.contains("jump-code-not-for-output"))
    }

    func testAuthFailureBeforeSecondFactorKeepsPrimaryCredentialGuidance() async {
        let client = ScriptedCheckedFFIClient(connect: [.init(.error("ssh_auth_failed"))])
        let coordinator = HostKeyTrustCoordinator(client: client)
        _ = await coordinator.begin(input: input())

        guard case let .failed(_, failure) = coordinator.state,
              case let .authentication(_, submittedSecondFactor) = failure else {
            return XCTFail("Expected primary authentication failure")
        }
        XCTAssertFalse(submittedSecondFactor)
        let recovery = OperationRecoveryMapper.connection(failure)
        XCTAssertEqual(recovery.message, "请检查凭据后重新连接。")
    }

    func testUnknownAwaitsDecisionAndCancelStopsFlow() async {
        let client = ScriptedCheckedFFIClient(connect: [.init(.challenge)])
        let coordinator = HostKeyTrustCoordinator(client: client)
        let flowID = await coordinator.begin(input: input())

        guard case let .awaitingUserDecision(actualFlow, challenge) = coordinator.state else {
            return XCTFail("Expected challenge state")
        }
        XCTAssertEqual(actualFlow, flowID)
        XCTAssertEqual(challenge.reasonCode, .unknownHost)

        coordinator.cancel()
        XCTAssertEqual(coordinator.state, .cancelled(flowID))
        await coordinator.trustCurrentChallenge()
        let persistCount = await client.persistRequestIDs.count
        XCTAssertEqual(persistCount, 0)
    }

    func testTrustPersistsThenReconnectsWithFreshRequest() async {
        let client = ScriptedCheckedFFIClient(
            connect: [.init(.challenge), .init(.connected)],
            persist: [.init(.persisted)]
        )
        let coordinator = HostKeyTrustCoordinator(client: client)
        _ = await coordinator.begin(input: input())
        await coordinator.trustCurrentChallenge()

        guard case .connected = coordinator.state else {
            return XCTFail("Expected connected after persistence")
        }
        let connectIDs = await client.connectRequestIDs
        let persistIDs = await client.persistRequestIDs
        XCTAssertEqual(connectIDs.count, 2)
        XCTAssertEqual(persistIDs.count, 1)
        XCTAssertEqual(Set(connectIDs + persistIDs).count, 3)
    }

    func testPersistFailureDoesNotReconnectAndRetryOnlyRetriesSave() async {
        let client = ScriptedCheckedFFIClient(
            connect: [.init(.challenge), .init(.connected)],
            persist: [
                .init(.error("known_hosts_save_failed")),
                .init(.persisted),
            ]
        )
        let coordinator = HostKeyTrustCoordinator(client: client)
        _ = await coordinator.begin(input: input())
        await coordinator.trustCurrentChallenge()

        guard case .failed(_, .storeSave) = coordinator.state else {
            return XCTFail("Expected save failure")
        }
        let initialConnectCount = await client.connectRequestIDs.count
        let initialPersistCount = await client.persistRequestIDs.count
        XCTAssertEqual(initialConnectCount, 1)
        XCTAssertEqual(initialPersistCount, 1)

        await coordinator.retrySave()
        guard case .connected = coordinator.state else {
            return XCTFail("Expected reconnect only after retry persisted")
        }
        let retriedPersistCount = await client.persistRequestIDs.count
        let reconnectCount = await client.connectRequestIDs.count
        XCTAssertEqual(retriedPersistCount, 2)
        XCTAssertEqual(reconnectCount, 2)
    }

    func testChangedAndRevokedAreDistinctBlockedStates() async {
        for reason in [HostKeyBlockReasonCode.changed, .revoked] {
            let client = ScriptedCheckedFFIClient(connect: [.init(.blocked(reason))])
            let coordinator = HostKeyTrustCoordinator(client: client)
            _ = await coordinator.begin(input: input())

            guard case let .blocked(_, payload) = coordinator.state else {
                return XCTFail("Expected blocked state")
            }
            XCTAssertEqual(payload.reasonCode, reason)
        }
    }

    func testAuthNetworkStoreAndUnknownFailuresRemainStructured() async {
        let cases: [(String, (HostKeyTrustFailure) -> Bool)] = [
            ("ssh_auth_failed", { if case .authentication = $0 { true } else { false } }),
            ("ssh_connect_failed", { if case .network = $0 { true } else { false } }),
            ("known_hosts_read_failed", { if case .store = $0 { true } else { false } }),
            ("future_error", { if case .operation = $0 { true } else { false } }),
        ]

        for (code, matches) in cases {
            let client = ScriptedCheckedFFIClient(connect: [.init(.error(code))])
            let coordinator = HostKeyTrustCoordinator(client: client)
            _ = await coordinator.begin(input: input())
            guard case let .failed(_, failure) = coordinator.state else {
                return XCTFail("Expected failure for \(code)")
            }
            XCTAssertTrue(matches(failure), code)
        }

        let unknownClient = ScriptedCheckedFFIClient(
            connect: [.init(.clientError(.protocolViolation))]
        )
        let unknownCoordinator = HostKeyTrustCoordinator(client: unknownClient)
        _ = await unknownCoordinator.begin(input: input())
        guard case .failed(_, .client(.protocolViolation)) = unknownCoordinator.state else {
            return XCTFail("Expected fail-closed protocol error")
        }
    }

    func testStaleConnectAndChallengeMismatchDoNotAdvanceState() async {
        let staleClient = ScriptedCheckedFFIClient(
            connect: [.init(.connected, staleResponse: true)]
        )
        let staleCoordinator = HostKeyTrustCoordinator(client: staleClient)
        _ = await staleCoordinator.begin(input: input())
        guard case .connecting = staleCoordinator.state else {
            return XCTFail("Stale response must not update state")
        }

        let mismatchClient = ScriptedCheckedFFIClient(
            connect: [.init(.challengeWithMismatchedRequest)]
        )
        let mismatchCoordinator = HostKeyTrustCoordinator(client: mismatchClient)
        _ = await mismatchCoordinator.begin(input: input())
        guard case .connecting = mismatchCoordinator.state else {
            return XCTFail("Mismatched challenge must not update state")
        }
    }

    func testStalePersistResponseDoesNotReconnect() async {
        let client = ScriptedCheckedFFIClient(
            connect: [.init(.challenge), .init(.connected)],
            persist: [.init(.persisted, staleResponse: true)]
        )
        let coordinator = HostKeyTrustCoordinator(client: client)
        _ = await coordinator.begin(input: input())
        await coordinator.trustCurrentChallenge()

        guard case .persisting = coordinator.state else {
            return XCTFail("Stale persistence must not advance state")
        }
        let connectCount = await client.connectRequestIDs.count
        XCTAssertEqual(connectCount, 1)
    }

    func testCancelledFlowIgnoresLateConnectResponse() async {
        let client = ScriptedCheckedFFIClient(
            connect: [.init(.connected, delayNanoseconds: 30_000_000)]
        )
        let coordinator = HostKeyTrustCoordinator(client: client)
        let task = Task { await coordinator.begin(input: input()) }
        await Task.yield()
        guard case let .connecting(flowID, _) = coordinator.state else {
            task.cancel()
            return XCTFail("Expected in-flight connect")
        }

        coordinator.cancel()
        _ = await task.value
        XCTAssertEqual(coordinator.state, .cancelled(flowID))
    }

    func testCoordinatorTimeoutFailsClosed() async {
        let client = ScriptedCheckedFFIClient(
            connect: [.init(.connected, delayNanoseconds: 30_000_000)]
        )
        let coordinator = HostKeyTrustCoordinator(
            client: client,
            operationTimeoutNanoseconds: 1_000_000
        )

        _ = await coordinator.begin(input: input())
        guard case .failed(_, .timeout(nil)) = coordinator.state else {
            return XCTFail("Expected coordinator timeout")
        }
    }

    func testCancelledFlowIgnoresLatePersistResponse() async {
        let client = ScriptedCheckedFFIClient(
            connect: [.init(.challenge)],
            persist: [.init(.persisted, delayNanoseconds: 30_000_000)]
        )
        let coordinator = HostKeyTrustCoordinator(client: client)
        let flowID = await coordinator.begin(input: input())
        let task = Task { await coordinator.trustCurrentChallenge() }
        await Task.yield()
        guard case .persisting = coordinator.state else {
            task.cancel()
            return XCTFail("Expected in-flight persistence")
        }

        coordinator.cancel()
        await task.value
        XCTAssertEqual(coordinator.state, .cancelled(flowID))
        let reconnectCount = await client.connectRequestIDs.count
        XCTAssertEqual(reconnectCount, 1)
    }

    func testSequentialChallengesAndParallelCoordinatorsDoNotShareState() async {
        let firstClient = ScriptedCheckedFFIClient(
            connect: [.init(.challenge), .init(.challenge)],
            persist: [.init(.persisted)]
        )
        let secondClient = ScriptedCheckedFFIClient(connect: [.init(.connected)])
        let first = HostKeyTrustCoordinator(client: firstClient)
        let second = HostKeyTrustCoordinator(client: secondClient)

        _ = await first.begin(input: input())
        await first.trustCurrentChallenge()
        guard case let .awaitingUserDecision(_, secondChallenge) = first.state else {
            return XCTFail("Expected second challenge")
        }
        XCTAssertEqual(secondChallenge.challengeID, "challenge-2")

        _ = await second.begin(input: input(host: "other.example"))
        guard case .connected = second.state else {
            return XCTFail("Expected independent coordinator connection")
        }
        guard case .awaitingUserDecision = first.state else {
            return XCTFail("Second coordinator must not mutate first")
        }
    }

    private func input(host: String = "fixture.example") -> CheckedConnectInput {
        CheckedConnectInput(
            host: host,
            port: 2222,
            username: "fixture-user",
            credentialReference: CredentialAccessReference(
                id: UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
            )
        )
    }
}
