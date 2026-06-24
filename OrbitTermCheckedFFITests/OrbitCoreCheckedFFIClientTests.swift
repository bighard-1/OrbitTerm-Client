import Foundation
import XCTest

final class OrbitCoreCheckedFFIClientTests: XCTestCase {
    private let requestID = try! HostKeyRequestID(CheckedFFIFixtures.requestID)
    private let persistRequestID = try! HostKeyRequestID("99999999-8888-7777-6666-555555555555")
    private let baseSessionID = try! BaseSessionID(CheckedFFIFixtures.largeID)

    func testCStringReaderCopiesAndFreesExactlyOnce() throws {
        let counter = FreeCounter()
        let reader = reader(counter: counter)

        XCTAssertEqual(try reader.take(allocatedCString("fixture")), "fixture")
        XCTAssertEqual(counter.count, 1)
        XCTAssertThrowsError(try reader.take(nil)) { error in
            XCTAssertEqual(error as? CheckedFFIClientError, .nullCStringResult)
        }
        XCTAssertEqual(counter.count, 1)

        let invalid = UnsafeMutablePointer<CChar>.allocate(capacity: 2)
        invalid[0] = CChar(bitPattern: 0xff)
        invalid[1] = 0
        XCTAssertThrowsError(try reader.take(invalid)) { error in
            XCTAssertEqual(error as? CheckedFFIClientError, .invalidUTF8Result)
        }
        XCTAssertEqual(counter.count, 2)
    }

    func testConnectDecodesConnectedChallengeBlockedAndErrorWithoutNetwork() async throws {
        let cases: [(String, (CheckedConnectResponse) -> Bool)] = [
            (CheckedFFIFixtures.connected, { if case .connected = $0 { true } else { false } }),
            (CheckedFFIFixtures.challenge, { if case .challenge = $0 { true } else { false } }),
            (CheckedFFIFixtures.blockedChanged, { if case .blocked = $0 { true } else { false } }),
            (CheckedFFIFixtures.error, { if case .failure = $0 { true } else { false } })
        ]

        for (fixture, matches) in cases {
            let counter = FreeCounter()
            let client = makeClient(json: fixture, counter: counter)
            let response = try await client.connectChecked(requestID: requestID, input: input())
            XCTAssertEqual(response.requestID, requestID)
            XCTAssertTrue(matches(response.value))
            XCTAssertEqual(counter.count, 1)
        }
    }

    func testConnectRejectsRequestMismatchAndDecodeFailureStillFrees() async {
        let stale = CheckedFFIFixtures.connected.replacingOccurrences(
            of: CheckedFFIFixtures.requestID,
            with: CheckedFFIFixtures.staleRequestID
        )
        for (fixture, expected) in [
            (stale, CheckedFFIClientError.requestIDMismatch),
            ("not-json", CheckedFFIClientError.jsonDecodeFailed)
        ] {
            let counter = FreeCounter()
            let client = makeClient(json: fixture, counter: counter)
            do {
                _ = try await client.connectChecked(requestID: requestID, input: input())
                XCTFail("Expected fail-closed adapter error")
            } catch let error as CheckedFFIClientError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("Unexpected error type")
            }
            XCTAssertEqual(counter.count, 1)
        }
    }

    func testPersistSuccessUsesChallengeCorrelationAndLocalAttemptID() async throws {
        let counter = FreeCounter()
        let client = makeClient(json: CheckedFFIFixtures.trustPersisted, counter: counter)
        let response = try await client.acceptAndPersistHostKey(
            requestID: persistRequestID,
            challengeRequestID: requestID,
            challengeID: "challenge-fixture-1",
            comment: "fixture"
        )

        XCTAssertEqual(response.requestID, persistRequestID)
        guard case let .persisted(payload) = response.value else {
            return XCTFail("Expected persisted payload")
        }
        XCTAssertEqual(payload.challengeID, "challenge-fixture-1")
        XCTAssertEqual(counter.count, 1)
    }

    func testPersistErrorWithoutRustRequestRequiresMatchingChallengeID() async throws {
        let counter = FreeCounter()
        let client = makeClient(
            json: CheckedFFIFixtures.persistErrorWithoutRequest,
            counter: counter
        )
        let response = try await client.acceptAndPersistHostKey(
            requestID: persistRequestID,
            challengeRequestID: requestID,
            challengeID: "challenge-fixture-1",
            comment: nil
        )
        guard case let .failure(error) = response.value else {
            return XCTFail("Expected structured persistence error")
        }
        XCTAssertEqual(error.code, .known("known_hosts_save_failed"))
        XCTAssertEqual(response.requestID, persistRequestID)
        XCTAssertEqual(counter.count, 1)
    }

    func testPersistRejectsMismatchedChallengeCorrelation() async {
        let mismatch = CheckedFFIFixtures.persistErrorWithoutRequest.replacingOccurrences(
            of: "challenge-fixture-1",
            with: "challenge-other"
        )
        let counter = FreeCounter()
        let client = makeClient(json: mismatch, counter: counter)
        do {
            _ = try await client.acceptAndPersistHostKey(
                requestID: persistRequestID,
                challengeRequestID: requestID,
                challengeID: "challenge-fixture-1",
                comment: nil
            )
            XCTFail("Expected correlation failure")
        } catch let error as CheckedFFIClientError {
            XCTAssertEqual(error, .requestIDMismatch)
        } catch {
            XCTFail("Unexpected error type")
        }
        XCTAssertEqual(counter.count, 1)
    }

    func testTerminalOpenDecodesTypedPayloadAndRejectsUnexpectedOrUnknownKind() async throws {
        let successCounter = FreeCounter()
        let success = makeClient(json: CheckedFFIFixtures.terminalOpened, counter: successCounter)
        let response = try await success.openTerminalChecked(
            requestID: requestID,
            baseSessionID: baseSessionID,
            cols: 120,
            rows: 32
        )
        XCTAssertEqual(response.requestID, requestID)
        XCTAssertEqual(response.value.baseSessionID, baseSessionID)
        XCTAssertEqual(response.value.terminalChannelID.decimalString, "18446744073709551614")
        XCTAssertEqual(successCounter.count, 1)

        for (fixture, expected) in [
            (CheckedFFIFixtures.sftpOpened, CheckedFFIClientError.unexpectedKind(.sftpChannelOpened)),
            (CheckedFFIFixtures.unknownKind, CheckedFFIClientError.unknownKind("future_additive_kind"))
        ] {
            let counter = FreeCounter()
            let client = makeClient(json: fixture, counter: counter)
            do {
                _ = try await client.openTerminalChecked(
                    requestID: requestID,
                    baseSessionID: baseSessionID,
                    cols: 120,
                    rows: 32
                )
                XCTFail("Expected terminal kind rejection")
            } catch let error as CheckedFFIClientError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("Unexpected error type")
            }
            XCTAssertEqual(counter.count, 1)
        }
    }

    func testTerminalErrorPayloadAndInvalidSizeRemainStructured() async {
        let counter = FreeCounter()
        let client = makeClient(json: CheckedFFIFixtures.error, counter: counter)
        do {
            _ = try await client.openTerminalChecked(
                requestID: requestID,
                baseSessionID: baseSessionID,
                cols: 120,
                rows: 32
            )
            XCTFail("Expected FFI error")
        } catch let error as CheckedFFIClientError {
            guard case let .ffiErrorPayload(payload) = error else {
                return XCTFail("Expected structured FFI payload")
            }
            XCTAssertEqual(payload.code, .known("ssh_auth_failed"))
        } catch {
            XCTFail("Unexpected error type")
        }
        XCTAssertEqual(counter.count, 1)

        do {
            _ = try await client.openTerminalChecked(
                requestID: requestID,
                baseSessionID: baseSessionID,
                cols: 0,
                rows: 32
            )
            XCTFail("Expected local validation")
        } catch let error as CheckedFFIClientError {
            XCTAssertEqual(error, .invalidInput)
        } catch {
            XCTFail("Unexpected error type")
        }
        XCTAssertEqual(counter.count, 1, "Invalid input must not call the C boundary")
    }

    func testSFTPOpenDecodesTypedPayloadAndChecksBaseSession() async throws {
        let counter = FreeCounter()
        let client = makeClient(json: CheckedFFIFixtures.sftpOpened, counter: counter)

        let response = try await client.openSFTPChecked(
            requestID: requestID,
            baseSessionID: baseSessionID
        )

        XCTAssertEqual(response.requestID, requestID)
        XCTAssertEqual(response.value.baseSessionID, baseSessionID)
        XCTAssertEqual(response.value.sftpSessionID.decimalString, "72057594037927937")
        XCTAssertEqual(counter.count, 1)

        let mismatch = CheckedFFIFixtures.sftpOpened.replacingOccurrences(
            of: CheckedFFIFixtures.largeID,
            with: "72057594037927935"
        )
        let mismatchClient = makeClient(json: mismatch, counter: counter)
        do {
            _ = try await mismatchClient.openSFTPChecked(
                requestID: requestID,
                baseSessionID: baseSessionID
            )
            XCTFail("Expected base-session correlation failure")
        } catch let error as CheckedFFIClientError {
            XCTAssertEqual(error, .protocolViolation)
        }
    }

    func testSFTPOpenRejectsRequestErrorAndUnexpectedKind() async {
        let stale = CheckedFFIFixtures.sftpOpened.replacingOccurrences(
            of: CheckedFFIFixtures.requestID,
            with: CheckedFFIFixtures.staleRequestID
        )
        let cases: [(String, CheckedFFIClientError)] = [
            (stale, .requestIDMismatch),
            (CheckedFFIFixtures.error, .ffiErrorPayload(errorPayload())),
            (CheckedFFIFixtures.terminalOpened, .unexpectedKind(.terminalChannelOpened)),
            (CheckedFFIFixtures.unknownKind, .unknownKind("future_additive_kind"))
        ]

        for (fixture, expected) in cases {
            let counter = FreeCounter()
            let client = makeClient(json: fixture, counter: counter)
            do {
                _ = try await client.openSFTPChecked(
                    requestID: requestID,
                    baseSessionID: baseSessionID
                )
                XCTFail("Expected checked SFTP rejection")
            } catch let error as CheckedFFIClientError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("Unexpected error type")
            }
            XCTAssertEqual(counter.count, 1)
        }
    }

    func testMonitorSnapshotDecodesTypedPayloadAndChecksBaseSession() async throws {
        let counter = FreeCounter()
        let client = makeClient(json: CheckedFFIFixtures.monitorSnapshot, counter: counter)
        let monitorBaseSessionID = try BaseSessionID("72057594037927936")

        let response = try await client.monitorSnapshotChecked(
            requestID: requestID,
            baseSessionID: monitorBaseSessionID
        )

        XCTAssertEqual(response.requestID, requestID)
        XCTAssertEqual(response.value.baseSessionID, monitorBaseSessionID)
        XCTAssertEqual(response.value.stats.cpuUsagePercent, 12.3)
        XCTAssertEqual(response.value.diagnostics, [.pingUnavailable])
        XCTAssertEqual(counter.count, 1)

        let mismatch = CheckedFFIFixtures.monitorSnapshot.replacingOccurrences(
            of: "72057594037927936",
            with: "72057594037927935"
        )
        let mismatchClient = makeClient(json: mismatch, counter: counter)
        do {
            _ = try await mismatchClient.monitorSnapshotChecked(
                requestID: requestID,
                baseSessionID: monitorBaseSessionID
            )
            XCTFail("Expected base-session correlation failure")
        } catch let error as CheckedFFIClientError {
            XCTAssertEqual(error, .protocolViolation)
        }
    }

    func testMonitorSnapshotRejectsRequestErrorAndUnexpectedKind() async {
        let stale = CheckedFFIFixtures.monitorSnapshot.replacingOccurrences(
            of: CheckedFFIFixtures.requestID,
            with: CheckedFFIFixtures.staleRequestID
        )
        let cases: [(String, CheckedFFIClientError)] = [
            (stale, .requestIDMismatch),
            (CheckedFFIFixtures.error, .ffiErrorPayload(errorPayload())),
            (CheckedFFIFixtures.sftpOpened, .unexpectedKind(.sftpChannelOpened)),
            (CheckedFFIFixtures.unknownKind, .unknownKind("future_additive_kind"))
        ]

        for (fixture, expected) in cases {
            let counter = FreeCounter()
            let client = makeClient(json: fixture, counter: counter)
            do {
                _ = try await client.monitorSnapshotChecked(
                    requestID: requestID,
                    baseSessionID: baseSessionID
                )
                XCTFail("Expected checked Monitor rejection")
            } catch let error as CheckedFFIClientError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("Unexpected error type")
            }
            XCTAssertEqual(counter.count, 1)
        }
    }

    func testDockerAdaptersDecodeAllCheckedPayloads() async throws {
        let dockerBaseSessionID = try BaseSessionID("72057594037927936")
        let containerID = "abcdef123456"

        let list = try await makeClient(
            json: CheckedFFIFixtures.dockerContainers,
            counter: FreeCounter()
        ).dockerListChecked(requestID: requestID, baseSessionID: dockerBaseSessionID)
        XCTAssertEqual(list.value.baseSessionID, dockerBaseSessionID)
        XCTAssertEqual(list.value.containers.first?.id, containerID)

        let stats = try await makeClient(
            json: CheckedFFIFixtures.dockerStats,
            counter: FreeCounter()
        ).dockerStatsChecked(requestID: requestID, baseSessionID: dockerBaseSessionID)
        XCTAssertEqual(stats.value.baseSessionID, dockerBaseSessionID)
        XCTAssertEqual(stats.value.stats.first?.cpuPercent, 2.5)

        let logs = try await makeClient(
            json: CheckedFFIFixtures.dockerLogs,
            counter: FreeCounter()
        ).dockerLogsChecked(
            requestID: requestID,
            baseSessionID: dockerBaseSessionID,
            containerID: containerID,
            tail: 200
        )
        XCTAssertEqual(logs.value.containerID, containerID)
        XCTAssertEqual(logs.value.logs, "fixture log line")

        let action = try await makeClient(
            json: CheckedFFIFixtures.dockerAction,
            counter: FreeCounter()
        ).dockerActionChecked(
            requestID: requestID,
            baseSessionID: dockerBaseSessionID,
            containerID: containerID,
            action: "restart"
        )
        XCTAssertEqual(action.value.action, "restart")
        XCTAssertEqual(action.value.status, .completed)
    }

    func testDockerAdaptersRejectMismatchUnexpectedKindAndUnsafeInput() async throws {
        let dockerBaseSessionID = try BaseSessionID("72057594037927936")
        let stale = CheckedFFIFixtures.dockerContainers.replacingOccurrences(
            of: CheckedFFIFixtures.requestID,
            with: CheckedFFIFixtures.staleRequestID
        )
        let mismatch = CheckedFFIFixtures.dockerStats.replacingOccurrences(
            of: "72057594037927936",
            with: "72057594037927935"
        )

        do {
            _ = try await makeClient(json: stale, counter: FreeCounter())
                .dockerListChecked(requestID: requestID, baseSessionID: dockerBaseSessionID)
            XCTFail("Expected request mismatch")
        } catch let error as CheckedFFIClientError {
            XCTAssertEqual(error, .requestIDMismatch)
        }

        do {
            _ = try await makeClient(json: mismatch, counter: FreeCounter())
                .dockerStatsChecked(requestID: requestID, baseSessionID: dockerBaseSessionID)
            XCTFail("Expected base-session mismatch")
        } catch let error as CheckedFFIClientError {
            XCTAssertEqual(error, .protocolViolation)
        }

        do {
            _ = try await makeClient(json: CheckedFFIFixtures.monitorSnapshot, counter: FreeCounter())
                .dockerListChecked(requestID: requestID, baseSessionID: dockerBaseSessionID)
            XCTFail("Expected kind mismatch")
        } catch let error as CheckedFFIClientError {
            XCTAssertEqual(error, .unexpectedKind(.monitorSnapshot))
        }

        let counter = FreeCounter()
        let client = makeClient(json: CheckedFFIFixtures.dockerLogs, counter: counter)
        do {
            _ = try await client.dockerLogsChecked(
                requestID: requestID,
                baseSessionID: dockerBaseSessionID,
                containerID: "abcdef;rm -rf /",
                tail: 200
            )
            XCTFail("Expected local Docker validation")
        } catch let error as CheckedFFIClientError {
            XCTAssertEqual(error, .invalidInput)
        }
        XCTAssertEqual(counter.count, 0, "Unsafe input must not cross the C boundary")
    }

    func testDockerLogsDebugDescriptionRedactsApplicationOutput() throws {
        let payload = DockerLogsPayload(
            baseSessionID: try BaseSessionID("72057594037927936"),
            securityGeneration: .hostKeyVerified,
            containerID: "abcdef123456",
            logs: "fixture log line"
        )
        let output = String(reflecting: payload)
        XCTAssertFalse(output.contains("fixture log line"))
        XCTAssertTrue(output.contains("[REDACTED]"))
    }

    func testExecCheckedDecodesTypedPayloadAndChecksBaseSession() async throws {
        let execBaseSessionID = try BaseSessionID("72057594037927936")
        let counter = FreeCounter()
        let client = makeClient(json: CheckedFFIFixtures.execResult, counter: counter)

        let response = try await client.execChecked(
            requestID: requestID,
            baseSessionID: execBaseSessionID,
            command: "uptime && whoami",
            options: .defaults
        )

        XCTAssertEqual(response.requestID, requestID)
        XCTAssertEqual(response.value.baseSessionID, execBaseSessionID)
        XCTAssertEqual(response.value.exitStatus, 0)
        XCTAssertEqual(response.value.stdout, "fixture stdout")
        XCTAssertEqual(counter.count, 1)

        let mismatch = CheckedFFIFixtures.execResult.replacingOccurrences(
            of: "72057594037927936",
            with: "72057594037927935"
        )
        do {
            _ = try await makeClient(json: mismatch, counter: FreeCounter()).execChecked(
                requestID: requestID,
                baseSessionID: execBaseSessionID,
                command: "uptime",
                options: .defaults
            )
            XCTFail("Expected exec base-session mismatch")
        } catch let error as CheckedFFIClientError {
            XCTAssertEqual(error, .protocolViolation)
        }
    }

    func testExecCheckedRejectsStaleKindErrorAndUnsafeLocalInput() async throws {
        let execBaseSessionID = try BaseSessionID("72057594037927936")
        let stale = CheckedFFIFixtures.execResult.replacingOccurrences(
            of: CheckedFFIFixtures.requestID,
            with: CheckedFFIFixtures.staleRequestID
        )
        let cases: [(String, CheckedFFIClientError)] = [
            (stale, .requestIDMismatch),
            (CheckedFFIFixtures.error, .ffiErrorPayload(errorPayload())),
            (CheckedFFIFixtures.dockerLogs, .unexpectedKind(.dockerLogs)),
            (CheckedFFIFixtures.unknownKind, .unknownKind("future_additive_kind"))
        ]

        for (fixture, expected) in cases {
            let counter = FreeCounter()
            let client = makeClient(json: fixture, counter: counter)
            do {
                _ = try await client.execChecked(
                    requestID: requestID,
                    baseSessionID: execBaseSessionID,
                    command: "id",
                    options: .defaults
                )
                XCTFail("Expected checked exec rejection")
            } catch let error as CheckedFFIClientError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("Unexpected error type")
            }
            XCTAssertEqual(counter.count, 1)
        }

        let counter = FreeCounter()
        let client = makeClient(json: CheckedFFIFixtures.execResult, counter: counter)
        for command in ["", "echo one\necho two", "echo\tone"] {
            do {
                _ = try await client.execChecked(
                    requestID: requestID,
                    baseSessionID: execBaseSessionID,
                    command: command,
                    options: .defaults
                )
                XCTFail("Expected local command validation")
            } catch let error as CheckedFFIClientError {
                XCTAssertEqual(error, .invalidInput)
            } catch {
                XCTFail("Unexpected error type")
            }
        }
        XCTAssertEqual(counter.count, 0, "Unsafe command must not cross the C boundary")
    }

    func testExecPayloadDebugDescriptionRedactsOutput() throws {
        let payload = try ExecResultPayload(
            baseSessionID: try BaseSessionID("72057594037927936"),
            securityGeneration: .hostKeyVerified,
            exitStatus: 0,
            stdout: "stdout-secret",
            stderr: "stderr-secret",
            timedOut: false,
            stdoutTruncated: false,
            stderrTruncated: false
        )
        let output = String(reflecting: payload)
        XCTAssertFalse(output.contains("stdout-secret"))
        XCTAssertFalse(output.contains("stderr-secret"))
        XCTAssertTrue(output.contains("[REDACTED]"))
    }

    func testErrorsAndDebugDescriptionsExcludeCredentialsAndKnownHostsPath() async {
        let counter = FreeCounter()
        let client = makeClient(json: "not-json", counter: counter)
        do {
            _ = try await client.connectChecked(requestID: requestID, input: input())
            XCTFail("Expected decode failure")
        } catch {
            let output = String(reflecting: error)
            for forbidden in [
                "fixture-password",
                "fixture-private-key",
                "fixture-passphrase",
                "/fixture/Application Support/OrbitTerm/Security/known_hosts"
            ] {
                XCTAssertFalse(output.contains(forbidden))
            }
        }
        XCTAssertFalse(String(reflecting: credentials()).contains("fixture-password"))
        XCTAssertEqual(counter.count, 1)
    }

    func testApplicationSupportProviderUsesOrbitTermSecurityStore() throws {
        let path = try ApplicationSupportKnownHostsPathProvider().knownHostsPath()
        XCTAssertTrue(path.hasSuffix("/OrbitTerm/Security/known_hosts"))
        XCTAssertFalse(path.hasSuffix("/.ssh/known_hosts"))
        XCTAssertFalse(path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    private func makeClient(json: String, counter: FreeCounter) -> OrbitCoreCheckedFFIClient {
        let functions = OrbitCoreCheckedFFIFunctions(
            connect: { _ in allocatedCString(json) },
            persist: { _ in allocatedCString(json) },
            openTerminal: { _ in allocatedCString(json) },
            openSFTP: { _ in allocatedCString(json) },
            monitorSnapshot: { _ in allocatedCString(json) },
            dockerList: { _ in allocatedCString(json) },
            dockerStats: { _ in allocatedCString(json) },
            dockerLogs: { _ in allocatedCString(json) },
            dockerAction: { _ in allocatedCString(json) },
            execChecked: { _ in allocatedCString(json) }
        )
        return OrbitCoreCheckedFFIClient(
            credentialProvider: FixtureCredentialProvider(value: credentials()),
            knownHostsPathProvider: FixtureKnownHostsPathProvider(),
            functions: functions,
            resultReader: reader(counter: counter)
        )
    }

    private func reader(counter: FreeCounter) -> OrbitCStringResultReader {
        OrbitCStringResultReader { pointer in
            pointer.deallocate()
            counter.increment()
        }
    }

    private func input() -> CheckedConnectInput {
        CheckedConnectInput(
            host: "fixture.example",
            port: 2222,
            username: "fixture-user",
            credentialReference: CredentialAccessReference()
        )
    }

    private func credentials() -> CheckedCredentials {
        CheckedCredentials(
            password: "fixture-password",
            privateKey: "fixture-private-key",
            privateKeyPassphrase: "fixture-passphrase",
            allowPasswordFallback: true
        )
    }

    private func errorPayload() -> CheckedFFIErrorPayload {
        CheckedFFIErrorPayload(
            code: .known("ssh_auth_failed"),
            messageKey: "error.ssh.auth_failed",
            detailCode: "authentication_rejected",
            retryable: true,
            requestID: requestID,
            challengeID: nil
        )
    }
}

private struct FixtureCredentialProvider: CheckedCredentialProvider {
    let value: CheckedCredentials

    func credentials(for reference: CredentialAccessReference) async throws -> CheckedCredentials {
        _ = reference
        return value
    }
}

private struct FixtureKnownHostsPathProvider: KnownHostsPathProvider {
    func knownHostsPath() throws -> String {
        "/fixture/Application Support/OrbitTerm/Security/known_hosts"
    }
}

private final class FreeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

private func allocatedCString(_ value: String) -> UnsafeMutablePointer<CChar> {
    let bytes = Array(value.utf8)
    let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
    for (index, byte) in bytes.enumerated() {
        pointer[index] = CChar(bitPattern: byte)
    }
    pointer[bytes.count] = 0
    return pointer
}
