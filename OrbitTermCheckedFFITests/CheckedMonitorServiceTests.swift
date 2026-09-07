import Foundation
import XCTest

final class CheckedMonitorServiceTests: XCTestCase {
    private let baseSessionID = try! BaseSessionID("72057594037927936")

    func testVerifiedBaseFetchesSnapshotWithoutConnectOrSFTPPath() async throws {
        let client = ScriptedCheckedFFIClient(
            connect: [],
            monitor: [.init(.snapshot)]
        )
        let service = CheckedMonitorSnapshotService(client: client)
        let binding = CheckedMonitorBinding(
            workspaceID: UUID(),
            baseSessionID: baseSessionID
        )

        let payload = try await service.snapshot(binding: binding)

        XCTAssertEqual(payload.baseSessionID, baseSessionID)
        XCTAssertEqual(payload.stats.cpuUsagePercent, 12.3)
        XCTAssertEqual(payload.diagnostics, [.pingUnavailable])
        let monitorCallCount = await client.monitorRequestIDs.count
        let connectCallCount = await client.connectRequestIDs.count
        let sftpCallCount = await client.sftpRequestIDs.count
        XCTAssertEqual(monitorCallCount, 1)
        XCTAssertEqual(connectCallCount, 0)
        XCTAssertEqual(sftpCallCount, 0)
    }

    func testEverySnapshotUsesFreshRequestID() async throws {
        let client = ScriptedCheckedFFIClient(
            connect: [],
            monitor: [.init(.snapshot), .init(.snapshot)]
        )
        let service = CheckedMonitorSnapshotService(client: client)
        let binding = CheckedMonitorBinding(
            workspaceID: UUID(),
            baseSessionID: baseSessionID
        )

        _ = try await service.snapshot(binding: binding)
        _ = try await service.snapshot(binding: binding)

        let requestIDs = await client.monitorRequestIDs
        XCTAssertEqual(requestIDs.count, 2)
        XCTAssertNotEqual(requestIDs[0], requestIDs[1])
    }

    func testStaleResponseAndClosedSessionFailClosed() async throws {
        let staleClient = ScriptedCheckedFFIClient(
            connect: [],
            monitor: [.init(.snapshot, staleResponse: true)]
        )
        let binding = CheckedMonitorBinding(
            workspaceID: UUID(),
            baseSessionID: baseSessionID
        )

        do {
            _ = try await CheckedMonitorSnapshotService(client: staleClient)
                .snapshot(binding: binding)
            XCTFail("Expected request mismatch")
        } catch let error as CheckedMonitorServiceError {
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
            monitor: [.init(.clientError(.ffiErrorPayload(payload)))]
        )
        do {
            _ = try await CheckedMonitorSnapshotService(client: closedClient)
                .snapshot(binding: binding)
            XCTFail("Expected closed-session failure")
        } catch let error as CheckedMonitorServiceError {
            XCTAssertEqual(error, .sessionClosed)
        }
        let connectCallCount = await closedClient.connectRequestIDs.count
        let sftpCallCount = await closedClient.sftpRequestIDs.count
        XCTAssertEqual(connectCallCount, 0)
        XCTAssertEqual(sftpCallCount, 0)
    }

    func testCheckedPolicyRequiresVerifiedSession() throws {
        let checked = MonitorConnectionPolicy(mode: .checkedRequired)
        XCTAssertEqual(
            checked.plan(verifiedSession: nil),
            .rejected(.requiresVerifiedSession)
        )

        let lease = VerifiedWorkspaceSession(
            workspaceID: UUID(),
            baseSessionID: baseSessionID,
            terminalChannelID: try TerminalChannelID("72057594037927938")
        )
        XCTAssertEqual(checked.plan(verifiedSession: lease), .checked(lease))
    }

    func testPollingRetriesTransientFailureWithoutReconnect() async throws {
        let client = ScriptedCheckedFFIClient(
            connect: [],
            monitor: [
                .init(.clientError(.timeout)),
                .init(.snapshot)
            ]
        )
        let binding = CheckedMonitorBinding(
            workspaceID: UUID(),
            baseSessionID: baseSessionID
        )
        let loop = CheckedMonitorPollingLoop(
            binding: binding,
            fetcher: CheckedMonitorSnapshotService(client: client),
            intervalNanoseconds: 1_000_000,
            retryDelayNanoseconds: 1_000_000
        )
        let events = EventRecorder()

        await loop.start { result in
            await events.append(result)
        }
        try await waitForEventCount(2, in: events)

        let isRunning = await loop.isRunning()
        let monitorCallCount = await client.monitorRequestIDs.count
        let connectCallCount = await client.connectRequestIDs.count
        let sftpCallCount = await client.sftpRequestIDs.count
        XCTAssertTrue(isRunning)
        XCTAssertGreaterThanOrEqual(monitorCallCount, 2)
        XCTAssertEqual(connectCallCount, 0)
        XCTAssertEqual(sftpCallCount, 0)
        let recorded = await events.values
        XCTAssertGreaterThanOrEqual(recorded.count, 2)
        guard case .failure(.unknownCheckedFFIError) = recorded[0] else {
            return XCTFail("Expected a structured transient failure")
        }
        guard recorded.contains(where: { if case .success = $0 { return true }; return false }) else {
            return XCTFail("Expected polling to recover with a subsequent snapshot")
        }
        await loop.stop()
    }

    private func waitForEventCount(
        _ expectedCount: Int,
        in recorder: EventRecorder,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async throws {
        let pollNanoseconds: UInt64 = 5_000_000
        var elapsed: UInt64 = 0
        while await recorder.values.count < expectedCount, elapsed < timeoutNanoseconds {
            try await Task.sleep(nanoseconds: pollNanoseconds)
            elapsed += pollNanoseconds
        }
    }

    func testPollingStopsForClosedVerifiedSession() async throws {
        let payload = CheckedFFIErrorPayload(
            code: .known("session_closed"),
            messageKey: "error.session.closed",
            detailCode: nil,
            retryable: false,
            requestID: nil,
            challengeID: nil
        )
        let client = ScriptedCheckedFFIClient(
            connect: [],
            monitor: [.init(.clientError(.ffiErrorPayload(payload)))]
        )
        let loop = CheckedMonitorPollingLoop(
            binding: CheckedMonitorBinding(workspaceID: UUID(), baseSessionID: baseSessionID),
            fetcher: CheckedMonitorSnapshotService(client: client),
            intervalNanoseconds: 1_000_000
        )
        let events = EventRecorder()

        await loop.start { result in
            await events.append(result)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let isRunning = await loop.isRunning()
        let monitorCallCount = await client.monitorRequestIDs.count
        XCTAssertFalse(isRunning)
        XCTAssertEqual(monitorCallCount, 1)
        let recorded = await events.values
        XCTAssertEqual(recorded.count, 1)
        guard case .failure(.sessionClosed) = recorded[0] else {
            return XCTFail("Expected a terminal checked-session failure")
        }
    }

    func testCancelledPollingIgnoresLateResponse() async throws {
        let client = ScriptedCheckedFFIClient(
            connect: [],
            monitor: [.init(.snapshot, delayNanoseconds: 200_000_000)]
        )
        let binding = CheckedMonitorBinding(
            workspaceID: UUID(),
            baseSessionID: baseSessionID
        )
        let loop = CheckedMonitorPollingLoop(
            binding: binding,
            fetcher: CheckedMonitorSnapshotService(client: client),
            intervalNanoseconds: 1_000_000
        )
        let events = EventRecorder()

        await loop.start { result in
            await events.append(result)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await loop.stop()
        try await Task.sleep(nanoseconds: 250_000_000)

        let isRunning = await loop.isRunning()
        let recorded = await events.values
        XCTAssertFalse(isRunning)
        XCTAssertTrue(recorded.isEmpty)
    }

    func testErrorsAreStableAndRedacted() {
        let errors: [CheckedMonitorServiceError] = [
            .requiresVerifiedSession,
            .legacyMonitorDisabledInCheckedMode,
            .checkedMonitorSnapshotFailed(.known("exec_timeout")),
            .sessionClosed,
            .unknownCheckedFFIError
        ]
        for error in errors {
            let output = String(reflecting: error)
            for forbidden in ["password", "private_key", "known_hosts", "fixture.example"] {
                XCTAssertFalse(output.contains(forbidden))
            }
        }
    }

    func testOnlyTransientCheckedErrorsRemainRetryable() {
        XCTAssertTrue(CheckedMonitorServiceError.unknownCheckedFFIError.shouldContinuePolling)
        XCTAssertTrue(
            CheckedMonitorServiceError.checkedMonitorSnapshotFailed(.known("exec_timeout"))
                .shouldContinuePolling
        )
        XCTAssertFalse(CheckedMonitorServiceError.sessionClosed.shouldContinuePolling)
        XCTAssertFalse(CheckedMonitorServiceError.requestIDMismatch.shouldContinuePolling)
    }
}

private actor EventRecorder {
    private(set) var values: [Result<MonitorSnapshotPayload, CheckedMonitorServiceError>] = []

    func append(_ value: Result<MonitorSnapshotPayload, CheckedMonitorServiceError>) {
        values.append(value)
    }
}
