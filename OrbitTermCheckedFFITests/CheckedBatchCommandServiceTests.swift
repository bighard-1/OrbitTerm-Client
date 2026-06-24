import Foundation
import XCTest

final class CheckedBatchCommandServiceTests: XCTestCase {
    private let baseSessionID = try! BaseSessionID("72057594037927936")

    func testVerifiedBaseExecutesCheckedCommandWithoutConnectOrSFTPPath() async throws {
        let client = ScriptedCheckedFFIClient(
            connect: [],
            exec: [.init(.success)]
        )
        let service = CheckedBatchCommandService(client: client)

        let results = await service.execute(
            command: "uptime && whoami",
            targets: [target(baseSessionID: baseSessionID)],
            options: .defaults
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .succeeded)
        XCTAssertEqual(results[0].stdout, "fixture stdout")
        let execCalls = await client.execRequestIDs.count
        let connectCalls = await client.connectRequestIDs.count
        let sftpCalls = await client.sftpRequestIDs.count
        XCTAssertEqual(execCalls, 1)
        XCTAssertEqual(connectCalls, 0)
        XCTAssertEqual(sftpCalls, 0)
    }

    func testNoVerifiedBaseRequiresVerifiedSessionAndDoesNotExec() async throws {
        let client = ScriptedCheckedFFIClient(
            connect: [],
            exec: [.init(.success)]
        )
        let service = CheckedBatchCommandService(client: client)

        let results = await service.execute(
            command: "id",
            targets: [target(baseSessionID: nil)],
            options: .defaults
        )

        XCTAssertEqual(results.first?.status, .requiresVerifiedSession)
        XCTAssertEqual(results.first?.error, .requiresVerifiedSession)
        let execCalls = await client.execRequestIDs.count
        XCTAssertEqual(execCalls, 0)
    }

    func testCommandValidationRejectsUnsafeBoundaryButAllowsShellMetacharacters() throws {
        let validator = CheckedBatchCommandValidator()
        XCTAssertEqual(try validator.validate("uptime && whoami | sort"), "uptime && whoami | sort")

        let invalid: [(String, CheckedBatchCommandError)] = [
            ("", .invalidCommand),
            (String(repeating: "x", count: 16_385), .commandTooLarge),
            ("echo one\necho two", .multilineUnsupported),
            ("echo\tone", .invalidCommand),
            ("echo \u{0000} one", .invalidCommand),
            ("echo \u{0007} one", .invalidCommand)
        ]
        for (command, expected) in invalid {
            XCTAssertThrowsError(try validator.validate(command)) { error in
                XCTAssertEqual(error as? CheckedBatchCommandError, expected)
            }
        }
    }

    func testInvalidCommandNeverReachesCheckedClient() async throws {
        let client = ScriptedCheckedFFIClient(
            connect: [],
            exec: [.init(.success)]
        )
        let service = CheckedBatchCommandService(client: client)

        let results = await service.execute(
            command: "echo one\necho two",
            targets: [target(baseSessionID: baseSessionID)],
            options: .defaults
        )

        XCTAssertEqual(results.first?.status, .failed)
        XCTAssertEqual(results.first?.error, .multilineUnsupported)
        let execCalls = await client.execRequestIDs.count
        XCTAssertEqual(execCalls, 0)
    }

    func testEachTargetUsesUniqueRequestIDAndPreservesPerTargetStatus() async throws {
        let client = ScriptedCheckedFFIClient(
            connect: [],
            exec: [
                .init(.success),
                .init(.result(exitStatus: 2, stdout: "", stderr: "failed"))
            ]
        )
        let service = CheckedBatchCommandService(client: client)

        let results = await service.execute(
            command: "hostname",
            targets: [
                target(name: "one", baseSessionID: baseSessionID),
                target(name: "two", baseSessionID: baseSessionID)
            ],
            options: .defaults
        )

        XCTAssertEqual(results.map(\.status), [.succeeded, .failed])
        XCTAssertEqual(results[1].error, .execCommandFailed(2))
        let requestIDs = await client.execRequestIDs
        XCTAssertEqual(requestIDs.count, 2)
        XCTAssertNotEqual(requestIDs[0], requestIDs[1])
    }

    func testRequestMismatchTimeoutAndOutputLimitFailClosedWithoutFallback() async throws {
        let staleClient = ScriptedCheckedFFIClient(
            connect: [],
            exec: [.init(.success, staleResponse: true)]
        )
        let staleResults = await CheckedBatchCommandService(client: staleClient).execute(
            command: "id",
            targets: [target(baseSessionID: baseSessionID)],
            options: .defaults
        )
        XCTAssertEqual(staleResults.first?.error, .requestIDMismatch)

        let timeoutPayload = CheckedFFIErrorPayload(
            code: .known("exec_timeout"),
            messageKey: "error.exec.timeout",
            detailCode: nil,
            retryable: false,
            requestID: nil,
            challengeID: nil
        )
        let timeoutClient = ScriptedCheckedFFIClient(
            connect: [],
            exec: [.init(.clientError(.ffiErrorPayload(timeoutPayload)))]
        )
        let timeoutResults = await CheckedBatchCommandService(client: timeoutClient).execute(
            command: "id",
            targets: [target(baseSessionID: baseSessionID)],
            options: .defaults
        )
        XCTAssertEqual(timeoutResults.first?.error, .execTimeout)
        let connectCalls = await timeoutClient.connectRequestIDs.count
        let sftpCalls = await timeoutClient.sftpRequestIDs.count
        XCTAssertEqual(connectCalls, 0)
        XCTAssertEqual(sftpCalls, 0)

        let truncatedClient = ScriptedCheckedFFIClient(
            connect: [],
            exec: [.init(.outputTruncated)]
        )
        let truncatedResults = await CheckedBatchCommandService(client: truncatedClient).execute(
            command: "id",
            targets: [target(baseSessionID: baseSessionID)],
            options: .defaults
        )
        XCTAssertEqual(truncatedResults.first?.error, .execOutputLimitExceeded)
    }

    func testCancelIgnoresLateResponse() async throws {
        let client = ScriptedCheckedFFIClient(
            connect: [],
            exec: [.init(.success, delayNanoseconds: 200_000_000)]
        )
        let service = CheckedBatchCommandService(client: client)
        let task = Task {
            await service.execute(
                command: "id",
                targets: [target(baseSessionID: baseSessionID)],
                options: .defaults
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await service.cancel()
        let results = await task.value

        XCTAssertEqual(results.first?.status, .cancelled)
        XCTAssertEqual(results.first?.error, .batchCancelled)
    }

    func testPolicyAndErrorsAreStableAndRedacted() throws {
        XCTAssertEqual(
            BatchCommandConnectionPolicy(mode: .checkedRequired).plan(targets: []),
            .rejected(.requiresVerifiedSession)
        )
        let checkedTarget = target(baseSessionID: baseSessionID)
        XCTAssertEqual(
            BatchCommandConnectionPolicy(mode: .checkedRequired).plan(targets: [checkedTarget]),
            .checked([checkedTarget])
        )

        let result = CheckedBatchTargetResult(
            workspaceID: UUID(),
            displayName: "fixture",
            endpoint: "fixture.example:22",
            status: .failed,
            exitStatus: 1,
            stdout: "stdout-secret",
            stderr: "stderr-secret",
            error: .execCommandFailed(1),
            durationMS: 1
        )
        XCTAssertFalse(String(reflecting: result).contains("stdout-secret"))
        XCTAssertFalse(String(reflecting: result).contains("stderr-secret"))

        for error in [
            CheckedBatchCommandError.invalidCommand,
            .commandTooLarge,
            .requiresVerifiedSession,
            .checkedExecFailed(.known("invalid_command"))
        ] {
            let output = String(reflecting: error)
            for forbidden in ["password", "private_key", "known_hosts", "uptime && whoami"] {
                XCTAssertFalse(output.contains(forbidden))
            }
        }
    }

    private func target(
        name: String = "fixture",
        baseSessionID: BaseSessionID?
    ) -> CheckedBatchTarget {
        CheckedBatchTarget(
            workspaceID: UUID(),
            displayName: name,
            endpoint: "fixture.example:22",
            baseSessionID: baseSessionID
        )
    }
}
