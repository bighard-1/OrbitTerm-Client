import Foundation
import XCTest

final class CheckedSFTPServiceTests: XCTestCase {
    func testVerifiedBaseOpensTypedSFTPWithoutConnectPath() async throws {
        let client = ScriptedCheckedFFIClient(
            connect: [],
            sftp: [.init(.opened)]
        )
        let service = CheckedSFTPConnectionService(client: client)
        let workspaceID = UUID()
        let baseSessionID = try BaseSessionID("72057594037927936")

        let connection = try await service.open(
            workspaceID: workspaceID,
            baseSessionID: baseSessionID
        )

        XCTAssertEqual(connection.workspaceID, workspaceID)
        XCTAssertEqual(connection.baseSessionID, baseSessionID)
        XCTAssertEqual(connection.sftpSessionID.decimalString, "72057594037927937")
        let sftpCalls = await client.sftpRequestIDs.count
        let connectCalls = await client.connectRequestIDs.count
        XCTAssertEqual(sftpCalls, 1)
        XCTAssertEqual(connectCalls, 0, "SFTP open must not initiate checked or legacy SSH connect")
    }

    func testSFTPRequestMismatchFailsClosed() async throws {
        let client = ScriptedCheckedFFIClient(
            connect: [],
            sftp: [.init(.opened, staleResponse: true)]
        )
        let service = CheckedSFTPConnectionService(client: client)

        do {
            _ = try await service.open(
                workspaceID: UUID(),
                baseSessionID: try BaseSessionID("72057594037927936")
            )
            XCTFail("Expected stale SFTP response rejection")
        } catch let error as CheckedSFTPServiceError {
            XCTAssertEqual(error, .requestIDMismatch)
        }
    }

    func testSFTPOpenFailureRemainsStructuredWithoutFallback() async throws {
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
            sftp: [.init(.clientError(.ffiErrorPayload(payload)))]
        )
        let service = CheckedSFTPConnectionService(client: client)

        do {
            _ = try await service.open(
                workspaceID: UUID(),
                baseSessionID: try BaseSessionID("72057594037927936")
            )
            XCTFail("Expected closed-session rejection")
        } catch let error as CheckedSFTPServiceError {
            XCTAssertEqual(error, .sessionClosed)
        }
        let connectCalls = await client.connectRequestIDs.count
        XCTAssertEqual(connectCalls, 0)
    }

    func testCheckedPolicyRequiresVerifiedSession() throws {
        let checked = SFTPConnectionPolicy(mode: .checkedRequired)
        XCTAssertEqual(
            checked.plan(verifiedSession: nil),
            .rejected(.requiresVerifiedSession)
        )

        let lease = VerifiedWorkspaceSession(
            workspaceID: UUID(),
            baseSessionID: try BaseSessionID("72057594037927936"),
            terminalChannelID: try TerminalChannelID("72057594037927938")
        )
        XCTAssertEqual(checked.plan(verifiedSession: lease), .checked(lease))
    }

    func testTypedSFTPBoundaryCannotSubstituteBaseOrTerminalID() throws {
        let connection = CheckedSFTPConnection(
            workspaceID: UUID(),
            baseSessionID: try BaseSessionID("72057594037927936"),
            sftpSessionID: try SFTPSessionID("72057594037927937")
        )

        XCTAssertEqual(connection.baseSessionID.ffiValue, 72_057_594_037_927_936)
        XCTAssertEqual(connection.sftpSessionID.ffiValue, 72_057_594_037_927_937)
        XCTAssertNotEqual(
            connection.baseSessionID.decimalString,
            connection.sftpSessionID.decimalString
        )
    }

    func testErrorsAreStableAndDoNotContainSensitiveContext() {
        let values: [CheckedSFTPServiceError] = [
            .requiresVerifiedSession,
            .legacySFTPDisabledInCheckedMode,
            .checkedSFTPOpenFailed(.known("channel_open_failed")),
            .unknownCheckedFFIError
        ]
        for error in values {
            let output = String(reflecting: error)
            XCTAssertFalse(output.contains("password"))
            XCTAssertFalse(output.contains("private_key"))
            XCTAssertFalse(output.contains("known_hosts"))
            XCTAssertFalse(output.contains("fixture.example"))
        }
    }
}
