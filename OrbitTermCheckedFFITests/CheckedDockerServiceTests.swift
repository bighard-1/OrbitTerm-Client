import Foundation
import XCTest

final class CheckedDockerServiceTests: XCTestCase {
    private let baseSessionID = try! BaseSessionID("72057594037927936")
    private let containerID = "abcdef123456"

    func testVerifiedBaseRefreshesListAndStatsWithoutOtherConnectionPaths() async throws {
        let client = ScriptedCheckedFFIClient(
            connect: [],
            dockerList: [.init(.success)],
            dockerStats: [.init(.success)]
        )
        let service = CheckedDockerOperationService(client: client)
        let refresh = try await service.refresh(binding: binding())

        XCTAssertEqual(refresh.containers.baseSessionID, baseSessionID)
        XCTAssertEqual(refresh.stats.baseSessionID, baseSessionID)
        XCTAssertEqual(refresh.containers.containers.first?.id, containerID)
        XCTAssertEqual(refresh.stats.stats.first?.cpuPercent, 2.5)

        let connectCalls = await client.connectRequestIDs.count
        let sftpCalls = await client.sftpRequestIDs.count
        let monitorCalls = await client.monitorRequestIDs.count
        XCTAssertEqual(connectCalls, 0)
        XCTAssertEqual(sftpCalls, 0)
        XCTAssertEqual(monitorCalls, 0)
    }

    func testLogsAndActionUseCheckedTypedOperations() async throws {
        let client = ScriptedCheckedFFIClient(
            connect: [],
            dockerLogs: [.init(.success)],
            dockerAction: [.init(.success)]
        )
        let service = CheckedDockerOperationService(client: client)

        let logs = try await service.logs(
            binding: binding(),
            containerID: containerID,
            tail: 200
        )
        let action = try await service.perform(
            binding: binding(),
            containerID: containerID,
            action: .restart
        )

        XCTAssertEqual(logs.containerID, containerID)
        XCTAssertEqual(logs.logs, "fixture log line")
        XCTAssertEqual(action.action, "restart")
        let logCalls = await client.dockerLogsRequestIDs.count
        let actionCalls = await client.dockerActionRequestIDs.count
        let connectCalls = await client.connectRequestIDs.count
        let sftpCalls = await client.sftpRequestIDs.count
        XCTAssertEqual(logCalls, 1)
        XCTAssertEqual(actionCalls, 1)
        XCTAssertEqual(connectCalls, 0)
        XCTAssertEqual(sftpCalls, 0)
    }

    func testRefreshUsesFreshRequestIDsForEveryOperation() async throws {
        let client = ScriptedCheckedFFIClient(
            connect: [],
            dockerList: [.init(.success), .init(.success)],
            dockerStats: [.init(.success), .init(.success)]
        )
        let service = CheckedDockerOperationService(client: client)

        _ = try await service.refresh(binding: binding())
        _ = try await service.refresh(binding: binding())

        let listIDs = await client.dockerListRequestIDs
        let statsIDs = await client.dockerStatsRequestIDs
        XCTAssertEqual(Set(listIDs + statsIDs).count, 4)
    }

    func testRequestMismatchAndClosedSessionFailClosedWithoutFallback() async throws {
        let staleClient = ScriptedCheckedFFIClient(
            connect: [],
            dockerList: [.init(.success, staleResponse: true)]
        )
        do {
            _ = try await CheckedDockerOperationService(client: staleClient)
                .refresh(binding: binding())
            XCTFail("Expected stale response rejection")
        } catch let error as CheckedDockerServiceError {
            XCTAssertEqual(error, .requestIDMismatch)
        }

        let payload = CheckedFFIErrorPayload(
            code: .known("session_closed"),
            messageKey: "error.session.closed",
            detailCode: nil,
            retryable: false,
            requestID: nil,
            challengeID: nil
        )
        let closedClient = ScriptedCheckedFFIClient(
            connect: [],
            dockerList: [.init(.clientError(.ffiErrorPayload(payload)))]
        )
        do {
            _ = try await CheckedDockerOperationService(client: closedClient)
                .refresh(binding: binding())
            XCTFail("Expected closed-session rejection")
        } catch let error as CheckedDockerServiceError {
            XCTAssertEqual(error, .sessionClosed)
        }
        let connectCalls = await closedClient.connectRequestIDs.count
        let sftpCalls = await closedClient.sftpRequestIDs.count
        XCTAssertEqual(connectCalls, 0)
        XCTAssertEqual(sftpCalls, 0)
    }

    func testUnsafeContainerIDNeverReachesCheckedClient() async throws {
        let client = ScriptedCheckedFFIClient(
            connect: [],
            dockerLogs: [.init(.success)],
            dockerAction: [.init(.success)]
        )
        let service = CheckedDockerOperationService(client: client)

        for value in ["short", "abcdef123456;rm -rf /", "abcdef123456$(id)"] {
            do {
                _ = try await service.logs(binding: binding(), containerID: value, tail: 100)
                XCTFail("Expected container ID rejection")
            } catch let error as CheckedDockerServiceError {
                XCTAssertEqual(error, .invalidContainerID)
            }
        }
        let logCalls = await client.dockerLogsRequestIDs.count
        XCTAssertEqual(logCalls, 0)
    }

    func testCheckedPolicyAndRenameUpdateStateAreFailClosed() throws {
        XCTAssertEqual(
            DockerConnectionPolicy(mode: .checkedRequired).plan(verifiedSession: nil),
            .rejected(.requiresVerifiedSession)
        )
        let lease = VerifiedWorkspaceSession(
            workspaceID: UUID(),
            baseSessionID: baseSessionID,
            terminalChannelID: try TerminalChannelID("72057594037927938")
        )
        XCTAssertEqual(
            DockerConnectionPolicy(mode: .checkedRequired).plan(verifiedSession: lease),
            .checked(lease)
        )
        XCTAssertEqual(
            CheckedDockerServiceError.renameUpdateDisabledInCheckedMode.userMessage,
            "此操作将在安全接口完成后启用"
        )
    }

    func testRefreshLoopStopsAfterFailureAndIgnoresCancelledLateResponse() async throws {
        let failingClient = ScriptedCheckedFFIClient(
            connect: [],
            dockerList: [.init(.clientError(.timeout))]
        )
        let failingLoop = CheckedDockerRefreshLoop(
            binding: binding(),
            operatorService: CheckedDockerOperationService(client: failingClient),
            intervalNanoseconds: 1_000_000
        )
        let failureEvents = DockerEventRecorder()
        await failingLoop.start { result in await failureEvents.append(result) }
        try await Task.sleep(nanoseconds: 50_000_000)

        let failureRunning = await failingLoop.isRunning()
        let failures = await failureEvents.values
        let failingListCalls = await failingClient.dockerListRequestIDs.count
        XCTAssertFalse(failureRunning)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failingListCalls, 1)

        let delayedClient = ScriptedCheckedFFIClient(
            connect: [],
            dockerList: [.init(.success, delayNanoseconds: 200_000_000)],
            dockerStats: [.init(.success)]
        )
        let delayedLoop = CheckedDockerRefreshLoop(
            binding: binding(),
            operatorService: CheckedDockerOperationService(client: delayedClient),
            intervalNanoseconds: 1_000_000
        )
        let delayedEvents = DockerEventRecorder()
        await delayedLoop.start { result in await delayedEvents.append(result) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await delayedLoop.stop()
        try await Task.sleep(nanoseconds: 250_000_000)

        let lateValues = await delayedEvents.values
        XCTAssertTrue(lateValues.isEmpty)
    }

    func testErrorsAndLogsDescriptionsAreRedacted() throws {
        let logs = DockerLogsPayload(
            baseSessionID: baseSessionID,
            securityGeneration: .hostKeyVerified,
            containerID: containerID,
            logs: "application-secret-output"
        )
        XCTAssertFalse(String(reflecting: logs).contains("application-secret-output"))

        for error in [
            CheckedDockerServiceError.requiresVerifiedSession,
            .legacyDockerDisabledInCheckedMode,
            .renameUpdateDisabledInCheckedMode,
            .checkedDockerOperationFailed(.known("exec_timeout"))
        ] {
            let output = String(reflecting: error)
            for forbidden in ["password", "private_key", "known_hosts", containerID] {
                XCTAssertFalse(output.contains(forbidden))
            }
        }
    }

    private func binding() -> CheckedDockerBinding {
        CheckedDockerBinding(workspaceID: UUID(), baseSessionID: baseSessionID)
    }
}

private actor DockerEventRecorder {
    private(set) var values: [Result<CheckedDockerRefresh, CheckedDockerServiceError>] = []

    func append(_ value: Result<CheckedDockerRefresh, CheckedDockerServiceError>) {
        values.append(value)
    }
}
