import Foundation
import XCTest

final class CheckedFFIIDTests: XCTestCase {
    func testBaseIDAcceptsCanonicalStringAndNumericUInt64() throws {
        let decoder = JSONDecoder()
        let stringID = try decoder.decode(BaseSessionID.self, from: Data("\"18446744073709551615\"".utf8))
        let numericID = try CheckedFFIWireDecoder.decode(
            BaseSessionID.self,
            from: Data("18446744073709551615".utf8),
            using: decoder
        )

        XCTAssertEqual(stringID.decimalString, UInt64.max.description)
        XCTAssertEqual(numericID, stringID)
        XCTAssertEqual(numericID.ffiValue, UInt64.max)
    }

    func testTypedStringIDsRemainDistinctAndCanonical() throws {
        let base = try BaseSessionID("00042")
        let sftp = try SFTPSessionID("42")
        let terminal = try TerminalChannelID("42")

        XCTAssertEqual(base.decimalString, "42")
        XCTAssertEqual(base.description, "base:42")
        XCTAssertEqual(sftp.description, "sftp:42")
        XCTAssertEqual(terminal.description, "terminal:42")
    }

    func testStringOnlyIDsRejectNumericJSON() {
        XCTAssertThrowsError(try JSONDecoder().decode(SFTPSessionID.self, from: Data("42".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(TerminalChannelID.self, from: Data("42".utf8)))
    }

    func testIDsRejectDoubleNegativeWhitespaceExponentZeroAndOverflow() {
        let invalidBaseJSON = ["1.0", "-1", "1e3", "0", "\"\"", "\" 1\"", "\"1 \"", "\"18446744073709551616\""]
        for value in invalidBaseJSON {
            XCTAssertThrowsError(try CheckedFFIWireDecoder.decode(BaseSessionID.self, from: Data(value.utf8)), value)
        }
    }

    func testRequestIDValidationAndRoundTrip() throws {
        let requestID = try HostKeyRequestID(CheckedFFIFixtures.requestID)
        let encoded = try JSONEncoder().encode(requestID)
        XCTAssertEqual(try JSONDecoder().decode(HostKeyRequestID.self, from: encoded), requestID)
        XCTAssertThrowsError(try HostKeyRequestID(""))
        XCTAssertThrowsError(try HostKeyRequestID("bad\nrequest"))
        XCTAssertThrowsError(try HostKeyRequestID(String(repeating: "x", count: 257)))
    }
}

final class CheckedFFIEnvelopeTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testSchemaOneAndUnknownFieldsDecode() throws {
        let envelope = try CheckedFFIWireDecoder.decode(
            CheckedFFIEnvelope<ConnectedPayload>.self,
            from: CheckedFFIFixtures.data(CheckedFFIFixtures.connected),
            using: decoder
        )
        XCTAssertEqual(envelope.schemaVersion, 1)
        XCTAssertEqual(envelope.kind, .connected)
        XCTAssertEqual(envelope.data?.sessionID.decimalString, UInt64.max.description)
    }

    func testErrorEnvelopeHasExclusiveErrorPayload() throws {
        let envelope = try CheckedFFIWireDecoder.decode(
            CheckedFFIEnvelope<ConnectedPayload>.self,
            from: CheckedFFIFixtures.data(CheckedFFIFixtures.error),
            using: decoder
        )
        XCTAssertNil(envelope.data)
        XCTAssertEqual(envelope.error?.code, .known("ssh_auth_failed"))
    }

    func testEnvelopeRejectsUnsupportedSchemaAndInvalidDataErrorShapes() {
        XCTAssertThrowsError(try CheckedFFIWireDecoder.decode(CheckedFFIEnvelope<ConnectedPayload>.self, from: CheckedFFIFixtures.data(CheckedFFIFixtures.unsupportedSchema), using: decoder))
        XCTAssertThrowsError(try CheckedFFIWireDecoder.decode(CheckedFFIEnvelope<ConnectedPayload>.self, from: CheckedFFIFixtures.data(CheckedFFIFixtures.bothPresent), using: decoder))
        XCTAssertThrowsError(try CheckedFFIWireDecoder.decode(CheckedFFIEnvelope<ConnectedPayload>.self, from: CheckedFFIFixtures.data(CheckedFFIFixtures.bothMissing), using: decoder))
    }

    func testUnknownKindIsRetainedByEnvelope() throws {
        struct FuturePayload: Decodable { let value: Bool }
        let envelope = try CheckedFFIWireDecoder.decode(
            CheckedFFIEnvelope<FuturePayload>.self,
            from: CheckedFFIFixtures.data(CheckedFFIFixtures.unknownKind),
            using: decoder
        )
        XCTAssertEqual(envelope.kind, .unknown("future_additive_kind"))
        XCTAssertEqual(envelope.data?.value, true)
    }

    func testRequestMismatchDetectsStaleResponse() throws {
        let envelope = try CheckedFFIWireDecoder.decode(
            CheckedFFIEnvelope<ConnectedPayload>.self,
            from: CheckedFFIFixtures.data(CheckedFFIFixtures.connected),
            using: decoder
        )
        XCTAssertThrowsError(try envelope.validateRequestID(HostKeyRequestID(CheckedFFIFixtures.staleRequestID)))
    }

    func testUnknownErrorCodeIsRetainedAndDescriptionIsRedacted() throws {
        let envelope = try CheckedFFIWireDecoder.decode(
            CheckedFFIEnvelope<ConnectedPayload>.self,
            from: CheckedFFIFixtures.data(CheckedFFIFixtures.unknownError),
            using: decoder
        )
        XCTAssertEqual(envelope.error?.code, .unknown("future_error_code"))
        XCTAssertFalse(String(describing: envelope.error).contains("fixture-must-be-ignored"))
    }
}

final class CheckedFFIPayloadTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testHostKeyPayloadsDecode() throws {
        let challenge = try decode(HostKeyChallengePayload.self, CheckedFFIFixtures.challenge)
        let changed = try decode(HostKeyBlockedPayload.self, CheckedFFIFixtures.blockedChanged)
        let revoked = try decode(HostKeyBlockedPayload.self, CheckedFFIFixtures.blockedRevoked)
        let persisted = try decode(TrustPersistedPayload.self, CheckedFFIFixtures.trustPersisted)

        XCTAssertEqual(challenge.reasonCode, .unknownHost)
        XCTAssertEqual(changed.reasonCode, .changed)
        XCTAssertEqual(revoked.reasonCode, .revoked)
        XCTAssertEqual(persisted.status, .trustedAdded)
    }

    func testSFTPAndMonitorPayloadsDecodeStringIDs() throws {
        let sftp = try decode(SFTPChannelOpenedPayload.self, CheckedFFIFixtures.sftpOpened)
        let monitor = try decode(MonitorSnapshotPayload.self, CheckedFFIFixtures.monitorSnapshot)

        XCTAssertEqual(sftp.baseSessionID.decimalString, UInt64.max.description)
        XCTAssertEqual(sftp.sftpSessionID.decimalString, "72057594037927937")
        XCTAssertEqual(monitor.baseSessionID.decimalString, "72057594037927936")
        XCTAssertEqual(monitor.diagnostics, [.pingUnavailable])
        XCTAssertEqual(monitor.stats.systemInfo.cpuThreadCount, 8)
        XCTAssertEqual(monitor.stats.systemInfo.diskTotalMB, 512_000)
    }

    func testTerminalPayloadUsesTypedStringIDsAndValidatedDimensions() throws {
        let terminal = try decode(
            TerminalChannelOpenedPayload.self,
            CheckedFFIFixtures.terminalOpened
        )

        XCTAssertEqual(terminal.baseSessionID.decimalString, UInt64.max.description)
        XCTAssertEqual(terminal.terminalChannelID.decimalString, "18446744073709551614")
        XCTAssertEqual(terminal.securityGeneration, .hostKeyVerified)
        XCTAssertEqual(terminal.cols, 120)
        XCTAssertEqual(terminal.rows, 32)
        XCTAssertFalse(String(reflecting: terminal).contains("future_terminal_field"))
    }

    func testTerminalPayloadRejectsInvalidIDDimensionsAndGeneration() {
        let invalidFixtures = [
            CheckedFFIFixtures.terminalOpened.replacingOccurrences(
                of: "\"terminal_channel_id\": \"18446744073709551614\"",
                with: "\"terminal_channel_id\": \"0\""
            ),
            CheckedFFIFixtures.terminalOpened.replacingOccurrences(of: "\"cols\": 120", with: "\"cols\": 0"),
            CheckedFFIFixtures.terminalOpened.replacingOccurrences(of: "\"rows\": 32", with: "\"rows\": 0"),
            CheckedFFIFixtures.terminalOpened.replacingOccurrences(
                of: "\"security_generation\": \"host_key_verified\"",
                with: "\"security_generation\": \"future_generation\""
            )
        ]
        for fixture in invalidFixtures {
            XCTAssertThrowsError(try decode(TerminalChannelOpenedPayload.self, fixture))
        }
    }

    func testTerminalKindRoundTripsAndUnknownKindRemainsDistinct() throws {
        let encoded = try JSONEncoder().encode(CheckedFFIResultKind.terminalChannelOpened)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"terminal_channel_opened\"")
        XCTAssertEqual(
            try JSONDecoder().decode(CheckedFFIResultKind.self, from: encoded),
            .terminalChannelOpened
        )
        XCTAssertEqual(CheckedFFIResultKind(rawValue: "future_terminal_kind"), .unknown("future_terminal_kind"))
    }

    func testDockerPayloadsDecode() throws {
        let containers = try decode(DockerContainersPayload.self, CheckedFFIFixtures.dockerContainers)
        let stats = try decode(DockerStatsPayload.self, CheckedFFIFixtures.dockerStats)
        let logs = try decode(DockerLogsPayload.self, CheckedFFIFixtures.dockerLogs)
        let action = try decode(DockerActionResultPayload.self, CheckedFFIFixtures.dockerAction)

        XCTAssertEqual(containers.containers.first?.id, "abcdef123456")
        XCTAssertEqual(stats.stats.first?.pids, 8)
        XCTAssertEqual(logs.logs, "fixture log line")
        XCTAssertEqual(action.status, .completed)
        XCTAssertFalse(String(reflecting: logs).contains("fixture log line"))
    }

    func testExecResultPayloadDecodesAndRedactsOutput() throws {
        let payload = try decode(ExecResultPayload.self, CheckedFFIFixtures.execResult)

        XCTAssertEqual(payload.baseSessionID.decimalString, "72057594037927936")
        XCTAssertEqual(payload.securityGeneration, .hostKeyVerified)
        XCTAssertEqual(payload.exitStatus, 0)
        XCTAssertEqual(payload.stdout, "fixture stdout")
        XCTAssertFalse(payload.timedOut)
        XCTAssertFalse(String(reflecting: payload).contains("fixture stdout"))
    }

    func testExecResultKindRoundTrips() throws {
        let encoded = try JSONEncoder().encode(CheckedFFIResultKind.execResult)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"exec_result\"")
        XCTAssertEqual(
            try JSONDecoder().decode(CheckedFFIResultKind.self, from: encoded),
            .execResult
        )
    }

    private func decode<Payload: Decodable>(_ type: Payload.Type, _ fixture: String) throws -> Payload {
        let envelope = try CheckedFFIWireDecoder.decode(
            CheckedFFIEnvelope<Payload>.self,
            from: CheckedFFIFixtures.data(fixture),
            using: decoder
        )
        return try XCTUnwrap(envelope.data)
    }
}

final class CheckedConnectResponseTests: XCTestCase {
    private let requestID = try! HostKeyRequestID(CheckedFFIFixtures.requestID)

    func testDispatchesConnectedChallengeBlockedAndError() throws {
        guard case let .connected(connected) = try decode(CheckedFFIFixtures.connected) else {
            return XCTFail("Expected connected response")
        }
        XCTAssertEqual(connected.sessionID.ffiValue, UInt64.max)

        guard case .challenge = try decode(CheckedFFIFixtures.challenge) else {
            return XCTFail("Expected challenge response")
        }
        guard case let .blocked(changed) = try decode(CheckedFFIFixtures.blockedChanged) else {
            return XCTFail("Expected blocked response")
        }
        XCTAssertEqual(changed.reasonCode, .changed)
        guard case let .failure(error) = try decode(CheckedFFIFixtures.error) else {
            return XCTFail("Expected error response")
        }
        XCTAssertEqual(error.code, .known("ssh_auth_failed"))
    }

    func testUnknownKindAndStaleResponseFailClosed() throws {
        XCTAssertThrowsError(try decode(CheckedFFIFixtures.unknownKind))
        let stale = try HostKeyRequestID(CheckedFFIFixtures.staleRequestID)
        XCTAssertThrowsError(try CheckedConnectResponse.decode(CheckedFFIFixtures.data(CheckedFFIFixtures.connected), expectedRequestID: stale))
    }

    private func decode(_ fixture: String) throws -> CheckedConnectResponse {
        try CheckedConnectResponse.decode(CheckedFFIFixtures.data(fixture), expectedRequestID: requestID)
    }
}
