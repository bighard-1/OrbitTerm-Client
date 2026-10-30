import Foundation
import XCTest

final class CheckedSFTPServiceTests: XCTestCase {
    func testLoopbackCheckedTransferPreservesExistingTargetsAndCancelsOwnedTarget() async throws {
        guard let configPath = ProcessInfo.processInfo.environment["ORBITTERM_SFTP_FIXTURE_CONFIG"] else {
            throw XCTSkip("Requires the private loopback SFTP fixture")
        }
        let config = try JSONDecoder().decode(
            LoopbackSFTPConfig.self, from: Data(contentsOf: URL(fileURLWithPath: configPath))
        )
        let root = URL(fileURLWithPath: config.root, isDirectory: true)
        let client = OrbitCoreCheckedFFIClient.live(
            credentialProvider: config, knownHostsPathProvider: config
        )
        let connected = try await client.connectChecked(
            requestID: HostKeyRequestID(),
            input: CheckedConnectInput(host: "127.0.0.1", port: config.port,
                                       username: "qa", credentialReference: CredentialAccessReference())
        )
        guard case let .connected(base) = connected.value else {
            switch connected.value {
            case let .failure(error): XCTFail("Loopback fixture connection code: \(error.code.rawValue)")
            case .challenge: XCTFail("Loopback fixture unexpectedly requested host key trust")
            case let .blocked(block): XCTFail("Loopback fixture trust blocked: \(block.reasonCode)")
            case .connected: break
            }
            return
        }
        let channel = try await CheckedSFTPConnectionService(client: client).open(
            workspaceID: UUID(), baseSessionID: base.sessionID
        )
        let sid = channel.sftpSessionID.ffiValue
        defer { _ = try? OrbitCStringResultReader.orbitCore.take(orbit_sftp_disconnect(sid)) }
        let source = try Data(contentsOf: root.appendingPathComponent("remote/virtual.bin"))
        let sentinel = root.appendingPathComponent("existing.bin")
        let original = Data("pre-existing-virtual-bytes".utf8)
        try original.write(to: sentinel, options: .withoutOverwriting)
        do {
            _ = try await SFTPCheckedTransfer.download(
                sessionID: sid, remotePath: "/virtual.bin", localURL: sentinel
            )
            XCTFail("Existing local target must not be overwritten")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("未覆盖"))
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), original)

        let fresh = root.appendingPathComponent("downloaded.bin")
        let downloaded = try await SFTPCheckedTransfer.download(
            sessionID: sid, remotePath: "/virtual.bin", localURL: fresh
        )
        XCTAssertEqual(downloaded, UInt64(source.count))
        XCTAssertEqual(try Data(contentsOf: fresh), source)

        let uploaded = try await SFTPCheckedTransfer.upload(
            sessionID: sid, localURL: fresh, remotePath: "/uploaded.bin"
        )
        XCTAssertEqual(uploaded, UInt64(source.count))
        do {
            _ = try await SFTPCheckedTransfer.upload(
                sessionID: sid, localURL: sentinel, remotePath: "/uploaded.bin"
            )
            XCTFail("Existing remote target must not be overwritten")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("未覆盖"))
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("remote/uploaded.bin")), source)

        let partial = root.appendingPathComponent("cancelled.bin")
        let transfer = Task {
            try await SFTPCheckedTransfer.download(
                sessionID: sid, remotePath: "/slow.bin", localURL: partial
            )
        }
        let marker = root.appendingPathComponent("slow-read-started")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let didStart = FileManager.default.fileExists(atPath: marker.path)
        transfer.cancel()
        do {
            _ = try await transfer.value
            XCTFail("Cancelled loopback transfer must not complete")
        } catch SFTPCheckedTransferError.cancelled {
            XCTAssertTrue(didStart, "Cancellation must happen after the core starts reading")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), original)

        // A lost/replaced connection must cancel the worker independently of
        // the Swift task which originally initiated the download.
        try FileManager.default.removeItem(at: marker)
        var registry = SFTPTransferOperationRegistry(maximumConcurrentOperations: 2)
        let scopedOperation = try XCTUnwrap(registry.begin())
        let scopedTarget = root.appendingPathComponent("scope-cancelled.bin")
        let scopedTransfer = Task {
            try await SFTPCheckedTransfer.download(
                sessionID: sid, remotePath: "/slow.bin", localURL: scopedTarget,
                cancellation: scopedOperation.cancellation
            )
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scopedReadStarted = FileManager.default.fileExists(atPath: marker.path)
        registry.cancelAll()
        XCTAssertEqual(registry.activeOperationCount, 1)
        do {
            _ = try await scopedTransfer.value
            XCTFail("Invalidated connection must stop its owned transfer")
        } catch SFTPCheckedTransferError.cancelled {
            XCTAssertTrue(scopedReadStarted)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scopedTarget.path))
        registry.finish(scopedOperation)
        XCTAssertEqual(registry.activeOperationCount, 0)
    }

    func testConnectionCancellationWaitsForCleanupAndDoesNotReleaseReconnectedWorkers() async throws {
        let started = expectation(description: "old worker entered")
        let cleanupStarted = expectation(description: "old worker cleaning up")
        let fixture = DelayedSFTPTransferRegistration(started: started, cleanupStarted: cleanupStarted)
        var registry = SFTPTransferOperationRegistry(maximumConcurrentOperations: 2)
        let old = try XCTUnwrap(registry.begin())
        let transfer = Task {
            try await SFTPCheckedTransfer.execute(
                sessionID: 42, remotePath: "/virtual.bin", direction: .download,
                cancellation: old.cancellation,
                operation: { try fixture.run($0) }, cancel: { fixture.cancel($0) }
            )
        }
        await fulfillment(of: [started], timeout: 2)
        // Invalidate before the core has registered its cancellable request.
        registry.cancelAll()
        let reconnected = try XCTUnwrap(registry.begin())
        XCTAssertFalse(reconnected.cancellation.isCancelled)
        fixture.allowRegistration.signal()
        await fulfillment(of: [cleanupStarted], timeout: 2)
        XCTAssertFalse(fixture.finished)
        XCTAssertEqual(registry.activeOperationCount, 2)
        XCTAssertNil(registry.begin(), "Stopping I/O still owns its resource slots")
        fixture.allowCleanup.signal()
        do {
            _ = try await transfer.value
            XCTFail("Connection cancellation must not report completion")
        } catch SFTPCheckedTransferError.cancelled {
            XCTAssertTrue(fixture.acceptedCancellation)
            XCTAssertTrue(fixture.finished)
        }
        registry.finish(old)
        XCTAssertEqual(registry.activeOperationCount, 1)
        registry.finish(old)
        XCTAssertEqual(registry.activeOperationCount, 1, "Duplicate old exit must not release new I/O")
        XCTAssertFalse(reconnected.cancellation.isCancelled)
        registry.cancelAll()
        XCTAssertTrue(reconnected.cancellation.isCancelled)
        registry.finish(reconnected)
        XCTAssertEqual(registry.activeOperationCount, 0)
    }

    func testCancelledConnectionCannotStartNewCoreWork() async throws {
        let cancellation = SFTPTransferCancellation()
        cancellation.cancel()
        do {
            _ = try await SFTPCheckedTransfer.execute(
                sessionID: 42, remotePath: "/virtual.bin", direction: .download,
                cancellation: cancellation,
                operation: { _ in XCTFail("Cancelled scope must not enter FFI"); return "{}" },
                cancel: { _ in false }
            )
            XCTFail("Cancelled scope must fail closed")
        } catch SFTPCheckedTransferError.cancelled {}
    }

    func testConnectionCancellationPreservesCleanupFailure() async throws {
        let started = expectation(description: "worker entered")
        let fixture = DelayedSFTPTransferRegistration(started: started, cleanupFailed: true)
        fixture.allowRegistration.signal()
        let cancellation = SFTPTransferCancellation()
        let transfer = Task {
            try await SFTPCheckedTransfer.execute(
                sessionID: 42, remotePath: "/virtual.bin", direction: .download,
                cancellation: cancellation,
                operation: { try fixture.run($0) }, cancel: { fixture.cancel($0) }
            )
        }
        await fulfillment(of: [started], timeout: 2)
        cancellation.cancel()
        do {
            _ = try await transfer.value
            XCTFail("Cleanup failure must not report success")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("目标清理失败"))
            XCTAssertTrue(fixture.finished)
        }
    }

    func testCancellationBeforeCoreRegistrationIsRetriedUntilTransferStops() async throws {
        let started = expectation(description: "blocking transfer entered")
        let fixture = DelayedSFTPTransferRegistration(started: started)
        let transfer = Task {
            try await SFTPCheckedTransfer.execute(
                sessionID: 42, remotePath: "/virtual.bin", direction: .download,
                operation: { try fixture.run($0) }, cancel: { fixture.cancel($0) }
            )
        }
        await fulfillment(of: [started], timeout: 2)
        transfer.cancel()
        XCTAssertFalse(fixture.acceptedCancellation)
        fixture.allowRegistration.signal()
        do {
            _ = try await transfer.value
            XCTFail("Cancelled transfer must not report completion")
        } catch SFTPCheckedTransferError.cancelled {
            XCTAssertTrue(fixture.acceptedCancellation)
            XCTAssertTrue(fixture.finished)
        }
    }

    func testTransferDeadlineCancelsCoreAndWaitsForItsExit() async throws {
        let started = expectation(description: "blocking transfer entered")
        let fixture = DelayedSFTPTransferRegistration(started: started)
        fixture.allowRegistration.signal()
        do {
            _ = try await SFTPCheckedTransfer.execute(
                sessionID: 42, remotePath: "/virtual.bin", direction: .download,
                timeout: 0.05, operation: { try fixture.run($0) }, cancel: { fixture.cancel($0) }
            )
            XCTFail("Deadline must stop transfer")
        } catch SFTPCheckedTransferError.timeout {
            XCTAssertTrue(fixture.acceptedCancellation)
            XCTAssertTrue(fixture.finished)
        }
        await fulfillment(of: [started], timeout: 2)
    }

    func testCleanupFailureRemainsVisibleAfterCancellation() async throws {
        let started = expectation(description: "blocking transfer entered")
        let fixture = DelayedSFTPTransferRegistration(started: started, cleanupFailed: true)
        fixture.allowRegistration.signal()
        let transfer = Task {
            try await SFTPCheckedTransfer.execute(
                sessionID: 42, remotePath: "/virtual.bin", direction: .download,
                operation: { try fixture.run($0) }, cancel: { fixture.cancel($0) }
            )
        }
        await fulfillment(of: [started], timeout: 2)
        transfer.cancel()
        do {
            _ = try await transfer.value
            XCTFail("Failed cleanup must not report completion")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("目标清理失败"))
            XCTAssertFalse(error.localizedDescription.contains("传输已取消"))
        }
    }

    func testCheckedTransferAcceptsOnlyMatchingVerifiedCompletion() throws {
        let request = try HostKeyRequestID("transfer-qa")
        let base: [String: Any] = [
            "schema_version": 1,
            "request_id": request.rawValue,
            "kind": "sftp_download_completed",
            "data": [
                "sftp_session_id": "42",
                "path": "/virtual.bin",
                "security_generation": "host_key_verified",
                "byte_length": 4096
            ]
        ]
        func response(_ value: [String: Any]) throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
        }
        XCTAssertEqual(try SFTPCheckedTransfer.decode(
            response(base), requestID: request, sessionID: 42,
            remotePath: "/virtual.bin", direction: .download
        ), 4096)

        var wrongRequest = base
        wrongRequest["request_id"] = "stale-transfer"
        var wrongSession = base
        wrongSession["data"] = [
            "sftp_session_id": "43", "path": "/virtual.bin",
            "security_generation": "host_key_verified", "byte_length": 4096
        ]
        var wrongPath = base
        wrongPath["data"] = [
            "sftp_session_id": "42", "path": "/other.bin",
            "security_generation": "host_key_verified", "byte_length": 4096
        ]
        var wrongGeneration = base
        wrongGeneration["data"] = [
            "sftp_session_id": "42", "path": "/virtual.bin",
            "security_generation": "legacy", "byte_length": 4096
        ]
        var wrongDirection = base
        wrongDirection["kind"] = "sftp_upload_completed"
        for invalid in [wrongRequest, wrongSession, wrongPath, wrongGeneration, wrongDirection] {
            XCTAssertThrowsError(try SFTPCheckedTransfer.decode(
                response(invalid), requestID: request, sessionID: 42,
                remotePath: "/virtual.bin", direction: .download
            ))
        }
    }

    func testCheckedTransferFailureUsesFixedMessageWithoutServerText() throws {
        let request = try HostKeyRequestID("transfer-error-qa")
        let response: [String: Any] = [
            "schema_version": 1,
            "request_id": request.rawValue,
            "kind": "error",
            "error": [
                "code": "sftp_download_failed",
                "message_key": "untrusted server text /private/fixture-path",
                "detail_code": "sftp_destination_exists",
                "retryable": false,
                "request_id": request.rawValue,
                "challenge_id": NSNull()
            ]
        ]
        let raw = String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)!
        do {
            _ = try SFTPCheckedTransfer.decode(
                raw, requestID: request, sessionID: 42,
                remotePath: "/virtual.bin", direction: .download
            )
            XCTFail("Existing local target must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("未覆盖"))
            XCTAssertFalse(error.localizedDescription.contains("/virtual.bin"))
        }
    }

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
            sftpSessionID: try SFTPSessionID("72057594037927937"),
            homePath: "/home/test"
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

private struct LoopbackSFTPConfig: Decodable, CheckedCredentialProvider, KnownHostsPathProvider {
    let port: UInt16
    let password: String
    let root: String

    func credentials(for reference: CredentialAccessReference) async throws -> CheckedCredentials {
        CheckedCredentials(password: password, privateKey: "", privateKeyPassphrase: "",
                           allowPasswordFallback: true)
    }

    func knownHostsPath() throws -> String {
        URL(fileURLWithPath: root).appendingPathComponent("orbitterm/known_hosts").path
    }
}

private final class DelayedSFTPTransferRegistration: @unchecked Sendable {
    let allowRegistration = DispatchSemaphore(value: 0)
    let allowCleanup = DispatchSemaphore(value: 0)
    private let stopped = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let started: XCTestExpectation
    private let cleanupFailed: Bool
    private let cleanupStarted: XCTestExpectation?
    private var registered = false
    private var accepted = false
    private var exited = false

    init(started: XCTestExpectation, cleanupFailed: Bool = false,
         cleanupStarted: XCTestExpectation? = nil) {
        self.started = started
        self.cleanupFailed = cleanupFailed
        self.cleanupStarted = cleanupStarted
    }
    var acceptedCancellation: Bool { lock.withLock { accepted } }
    var finished: Bool { lock.withLock { exited } }

    func run(_ request: String) throws -> String {
        started.fulfill()
        guard allowRegistration.wait(timeout: .now() + 3) == .success else {
            throw SFTPCheckedTransferError.invalidResponse
        }
        lock.withLock { registered = true }
        guard stopped.wait(timeout: .now() + 3) == .success else {
            throw SFTPCheckedTransferError.invalidResponse
        }
        if let cleanupStarted {
            cleanupStarted.fulfill()
            guard allowCleanup.wait(timeout: .now() + 3) == .success else {
                throw SFTPCheckedTransferError.invalidResponse
            }
        }
        lock.withLock { exited = true }
        let detail = cleanupFailed ? "sftp_local_cleanup_failed" : "sftp_transfer_cancelled"
        return """
        {"schema_version":1,"request_id":"\(request)","kind":"error","error":{
        "code":"sftp_download_failed","message_key":"error.sftp.download",
        "detail_code":"\(detail)","retryable":false,"request_id":"\(request)"}}
        """
    }

    func cancel(_ request: String) -> Bool {
        let shouldStop = lock.withLock {
            guard registered, !accepted else { return false }
            accepted = true
            return true
        }
        if shouldStop { stopped.signal() }
        return shouldStop
    }
}
