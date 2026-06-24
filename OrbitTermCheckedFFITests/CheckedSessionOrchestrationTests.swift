import Foundation
import XCTest

@MainActor
final class CheckedSessionOrchestrationTests: XCTestCase {
    func testCheckedRequiredDispatcherDoesNotFallbackToLegacy() async {
        let calls = CallCounter()
        await SessionConnectionDispatcher(policy: .checkedRequired).run(
            checked: { await calls.recordChecked() }
        )
        let snapshot = await calls.snapshot()
        XCTAssertEqual(snapshot.legacy, 0)
        XCTAssertEqual(snapshot.checked, 1)
    }

    func testApplicationDefaultRequiresCheckedNetwork() {
        XCTAssertEqual(ConnectionSecurityPolicy.applicationDefault, .checkedRequired)
        XCTAssertTrue(ConnectionSecurityPolicy.applicationDefault.requiresCheckedNetwork)
        XCTAssertFalse(ConnectionSecurityPolicy.applicationDefault.allowsLegacyNetwork)
        XCTAssertFalse(ConnectionSecurityPolicy.allowsLegacyConnectionTest)
        XCTAssertFalse(ConnectionSecurityPolicy.allowsLegacyQuickKeyDeployment)
    }

    func testDirectConnectedOpensCheckedTerminalAndReturnsTypedLease() async {
        let client = ScriptedCheckedFFIClient(
            connect: [.init(.connected)],
            terminal: [.init(.opened)]
        )
        let workspaceID = UUID()
        let orchestrator = CheckedTerminalConnectionOrchestrator(
            workspaceID: workspaceID,
            client: client
        )

        let outcome = await orchestrator.begin(input: input())

        guard case let .connected(lease) = outcome else {
            return XCTFail("Expected checked terminal lease")
        }
        XCTAssertEqual(lease.workspaceID, workspaceID)
        XCTAssertEqual(lease.baseSessionID.decimalString, "72057594037927936")
        XCTAssertEqual(lease.terminalChannelID?.decimalString, "72057594037927938")
        let terminalCount = await client.terminalRequestIDs.count
        XCTAssertEqual(terminalCount, 1)
    }

    func testUnknownAndCancelNeverOpenTerminal() async {
        let client = ScriptedCheckedFFIClient(connect: [.init(.challenge)])
        let orchestrator = CheckedTerminalConnectionOrchestrator(
            workspaceID: UUID(),
            client: client
        )

        let initialOutcome = await orchestrator.begin(input: input())
        let initialTerminalCount = await client.terminalRequestIDs.count
        XCTAssertEqual(initialOutcome, .awaitingUserDecision)
        XCTAssertEqual(initialTerminalCount, 0)
        XCTAssertEqual(orchestrator.cancel(), .cancelled)
        let cancelledTerminalCount = await client.terminalRequestIDs.count
        XCTAssertEqual(cancelledTerminalCount, 0)
    }

    func testPresentationRouteExposesCoordinatorChallengeState() async {
        let client = ScriptedCheckedFFIClient(connect: [.init(.challenge)])
        let workspaceID = UUID()
        let orchestrator = CheckedTerminalConnectionOrchestrator(
            workspaceID: workspaceID,
            client: client
        )
        let route = CheckedHostKeyPresentationRoute(
            workspaceID: workspaceID,
            orchestrator: orchestrator
        )

        _ = await orchestrator.begin(input: input())

        XCTAssertEqual(route.workspaceID, workspaceID)
        guard case .awaitingUserDecision = route.coordinator.state else {
            return XCTFail("Expected the mounted route to expose challenge state")
        }
    }

    func testPersistSuccessReconnectsThenOpensTerminal() async {
        let client = ScriptedCheckedFFIClient(
            connect: [.init(.challenge), .init(.connected)],
            persist: [.init(.persisted)],
            terminal: [.init(.opened)]
        )
        let orchestrator = CheckedTerminalConnectionOrchestrator(
            workspaceID: UUID(),
            client: client
        )

        let initialOutcome = await orchestrator.begin(input: input())
        XCTAssertEqual(initialOutcome, .awaitingUserDecision)
        guard case .connected = await orchestrator.trustCurrentChallenge() else {
            return XCTFail("Expected terminal after persisted trust and reconnect")
        }
        let connectCount = await client.connectRequestIDs.count
        let persistCount = await client.persistRequestIDs.count
        let terminalCount = await client.terminalRequestIDs.count
        XCTAssertEqual(connectCount, 2)
        XCTAssertEqual(persistCount, 1)
        XCTAssertEqual(terminalCount, 1)
    }

    func testPersistFailureDoesNotReconnectOrOpenTerminal() async {
        let client = ScriptedCheckedFFIClient(
            connect: [.init(.challenge), .init(.connected)],
            persist: [.init(.error("known_hosts_save_failed"))],
            terminal: [.init(.opened)]
        )
        let orchestrator = CheckedTerminalConnectionOrchestrator(
            workspaceID: UUID(),
            client: client
        )
        _ = await orchestrator.begin(input: input())

        guard case .failed(.storeSave) = await orchestrator.trustCurrentChallenge() else {
            return XCTFail("Expected structured store save failure")
        }
        let connectCount = await client.connectRequestIDs.count
        let terminalCount = await client.terminalRequestIDs.count
        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(terminalCount, 0)
    }

    func testBlockedAuthNetworkAndStaleResponsesNeverOpenTerminal() async {
        let cases: [ScriptedCheckedFFIClient.ConnectOutcome] = [
            .blocked(.changed),
            .blocked(.revoked),
            .error("ssh_auth_failed"),
            .error("ssh_connect_failed"),
        ]
        for outcome in cases {
            let client = ScriptedCheckedFFIClient(connect: [.init(outcome)])
            let orchestrator = CheckedTerminalConnectionOrchestrator(
                workspaceID: UUID(),
                client: client
            )
            _ = await orchestrator.begin(input: input())
            let terminalCount = await client.terminalRequestIDs.count
            XCTAssertEqual(terminalCount, 0)
        }

        let stale = ScriptedCheckedFFIClient(
            connect: [.init(.connected, staleResponse: true)],
            terminal: [.init(.opened)]
        )
        let orchestrator = CheckedTerminalConnectionOrchestrator(
            workspaceID: UUID(),
            client: stale
        )
        let staleOutcome = await orchestrator.begin(input: input())
        let staleTerminalCount = await stale.terminalRequestIDs.count
        XCTAssertEqual(staleOutcome, .pending)
        XCTAssertEqual(staleTerminalCount, 0)
    }

    func testTerminalFailurePreservesTypedBaseLeaseWithoutTerminal() async {
        let client = ScriptedCheckedFFIClient(
            connect: [.init(.connected)],
            terminal: [.init(.clientError(.ffiErrorPayload(errorPayload("pty_request_failed"))))]
        )
        let workspaceID = UUID()
        let orchestrator = CheckedTerminalConnectionOrchestrator(
            workspaceID: workspaceID,
            client: client
        )

        guard case let .terminalOpenFailed(lease, error) = await orchestrator.begin(input: input()) else {
            return XCTFail("Expected terminal-open failure")
        }
        XCTAssertEqual(lease.workspaceID, workspaceID)
        XCTAssertNil(lease.terminalChannelID)
        guard case .ffiErrorPayload = error else {
            return XCTFail("Expected structured terminal FFI error")
        }
    }

    func testCheckedSideServicesRemainDisabled() {
        let policy = CheckedSideServicePolicy.migrationPending
        XCTAssertFalse(policy.startsSFTP)
        XCTAssertFalse(policy.startsMonitor)
        XCTAssertFalse(policy.startsDocker)
        XCTAssertFalse(policy.startsBatch)
    }

    private func input() -> CheckedConnectInput {
        CheckedConnectInput(
            host: "fixture.example",
            port: 2222,
            username: "fixture-user",
            credentialReference: CredentialAccessReference(
                id: UUID(uuidString: "12345678-1234-1234-1234-123456789012")!,
                allowPasswordFallback: false
            )
        )
    }

    private func errorPayload(_ code: String) -> CheckedFFIErrorPayload {
        CheckedFFIErrorPayload(
            code: CheckedFFIErrorCode(rawValue: code),
            messageKey: "error.fixture",
            detailCode: nil,
            retryable: false,
            requestID: nil,
            challengeID: nil
        )
    }
}

private actor CallCounter {
    private var legacy = 0
    private var checked = 0

    func recordLegacy() { legacy += 1 }
    func recordChecked() { checked += 1 }
    func snapshot() -> (legacy: Int, checked: Int) { (legacy, checked) }
}
