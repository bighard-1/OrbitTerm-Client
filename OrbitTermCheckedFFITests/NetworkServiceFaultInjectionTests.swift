import Foundation
import XCTest

final class NetworkServiceFaultInjectionTests: XCTestCase {
    override func tearDown() {
        ScriptedURLProtocol.reset()
        super.tearDown()
    }

    func testRetryableResponsesWithoutServerDelayUseExactlyThreeNativeRequests() async {
        ScriptedURLProtocol.install([
            .init(statusCode: 503),
            .init(statusCode: 503),
            .init(statusCode: 409, body: #"{"success":false,"error":"final"}"#),
        ])
        let service = makeService()

        let failure = await registerFailure(service)

        guard case let .httpStatus(statusCode, retryAfterSeconds) = failure else {
            return XCTFail("Expected stable HTTP status failure, got \(failure)")
        }
        XCTAssertEqual(statusCode, 409)
        XCTAssertNil(retryAfterSeconds)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 3)
    }

    func testRetryAfterStopsInternalRetryAndSurvivesURLSessionPipeline() async {
        ScriptedURLProtocol.install([
            .init(statusCode: 429, headers: ["Retry-After": "120"]),
        ])
        let service = makeService()

        let failure = await registerFailure(service)

        guard case let .httpStatus(statusCode, retryAfterSeconds) = failure else {
            return XCTFail("Expected stable HTTP status failure, got \(failure)")
        }
        XCTAssertEqual(statusCode, 429)
        XCTAssertEqual(retryAfterSeconds, 120)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 1)
    }

    func testResponseBodyCannotChangePermanentStatusClassification() async {
        ScriptedURLProtocol.install([
            .init(
                statusCode: 422,
                body: #"{"success":false,"error":"authentication expired; retry conflict"}"#
            ),
        ])
        let service = makeService()

        let failure = await registerFailure(service)

        guard case let .httpStatus(statusCode, retryAfterSeconds) = failure else {
            return XCTFail("Expected stable HTTP status failure, got \(failure)")
        }
        XCTAssertEqual(statusCode, 422)
        XCTAssertNil(retryAfterSeconds)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 1)
    }

    func testAllowlistedServerAuthCodesAndOversizeResponse() async {
        let fixtures: [(Int, String, NetworkService.NetworkError)] = [
            (403, "PASSWORD_CHANGE_REQUIRED", .passwordChangeRequired),
            (409, "REFRESH_IN_PROGRESS", .refreshInProgress),
            (409, "AUTH_STATE_CHANGED", .authStateChanged),
            (413, "OTHER", .requestTooLarge),
        ]
        for (status, code, expected) in fixtures {
            ScriptedURLProtocol.install([
                .init(statusCode: status, body: #"{"success":false,"code":"\#(code)"}"#),
            ])
            let failure = await registerFailure(makeService())
            XCTAssertEqual(failure.localizedDescription, expected.localizedDescription)
            XCTAssertEqual(ScriptedURLProtocol.requestCount, 1)
        }
    }

    func testLoginResponseDecodesForcedPasswordChangeFlag() throws {
        let payload = #"{"access_token":"access","refresh_token":"refresh","type":"Bearer","must_change_password":true}"#
        let login = try JSONDecoder().decode(LoginData.self, from: Data(payload.utf8))
        XCTAssertEqual(login.must_change_password, true)
    }

    func testUnauthorizedRemainsAuthenticationFailureWithoutRetry() async {
        ScriptedURLProtocol.install([.init(statusCode: 401)])
        let service = makeService()

        let failure = await registerFailure(service)

        guard case .unauthorized = failure else {
            return XCTFail("Expected unauthorized failure, got \(failure)")
        }
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 1)
    }

    func testTimeoutAndConnectionLossUseBoundedNativeRetries() async {
        for failureCode in [URLError.Code.timedOut, .networkConnectionLost] {
            ScriptedURLProtocol.install([
                .failure(failureCode),
                .failure(failureCode),
                .init(statusCode: 422),
            ])

            let failure = await registerFailure(makeService())

            guard case let .httpStatus(statusCode, _) = failure else {
                XCTFail("Expected final HTTP response after transport retries, got \(failure)")
                continue
            }
            XCTAssertEqual(statusCode, 422)
            XCTAssertEqual(ScriptedURLProtocol.requestCount, 3)
        }
    }

    func testTruncatedResponseRetriesThenReturnsStableTransportFailure() async {
        ScriptedURLProtocol.install([
            .failure(.networkConnectionLost, partialBody: #"{"success":true,"data":{ "#),
            .failure(.networkConnectionLost, partialBody: #"{"success":true,"data":{ "#),
            .failure(.networkConnectionLost, partialBody: #"{"success":true,"data":{ "#),
        ])

        let failure = await rawRegisterFailure(makeService())

        XCTAssertEqual((failure as? URLError)?.code, .networkConnectionLost)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 3)
    }

    func testMalformedSuccessBodyIsProtocolViolationWithoutRetry() async {
        ScriptedURLProtocol.install([
            .init(statusCode: 200, body: #"{"success":true,"data":{ "#),
        ])

        let failure = await registerFailure(makeService())

        guard case .decodeFailed = failure else {
            return XCTFail("Expected decode failure, got \(failure)")
        }
        XCTAssertEqual(failure.syncRecoveryFailure, .protocolViolation)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 1)
    }

    func testCancellationNeverRetries() async {
        ScriptedURLProtocol.install([.failure(.cancelled)])

        let failure = await rawRegisterFailure(makeService())

        XCTAssertEqual((failure as? URLError)?.code, .cancelled)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 1)
    }

    func testCancellationDuringBackoffBalancesRetryPresentation() async {
        ScriptedURLProtocol.install([.init(statusCode: 503)])
        let diagnostics = await MainActor.run { DiagnosticsManager() }
        let service = makeService(retrySleeper: { _ in throw CancellationError() })
        service.configureDiagnostics(diagnostics)

        let failure = await rawRegisterFailure(service)

        XCTAssertTrue(failure is CancellationError)
        let retryCount = await MainActor.run { diagnostics.retryInFlightCount }
        XCTAssertEqual(retryCount, 0)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 1)
    }

    func testIdempotencyHeaderIsStableAcrossAutomaticNativeRetries() async {
        ScriptedURLProtocol.install([
            .init(statusCode: 503),
            .init(statusCode: 503),
            .init(statusCode: 422),
        ])
        let service = makeService()
        let key = String(repeating: "a", count: 64)

        do {
            try await service.performFaultInjectionProbe(idempotencyKey: key)
            XCTFail("Expected probe to fail")
        } catch let failure as NetworkService.NetworkError {
            guard case let .httpStatus(statusCode, _) = failure else {
                return XCTFail("Expected final HTTP status, got \(failure)")
            }
            XCTAssertEqual(statusCode, 422)
        } catch {
            XCTFail("Unexpected failure type: \(type(of: error))")
        }
        XCTAssertEqual(ScriptedURLProtocol.idempotencyKeys(), [key, key, key])
    }

    func testAssetDeleteConflictPersistsOnlyStableCategoryAndHTTPStatus() async {
        ScriptedURLProtocol.install([
            .init(statusCode: 409, body: #"{"success":false,"code":"ASSET_DELETED","error":"private-response-must-not-persist"}"#),
        ])
        let service = makeService()
        let assetID = fixtureAssetID
        let mutation = fixtureDeletionRequest

        let failure = await assetDeleteFailure(service, assetID: assetID, request: mutation)

        guard case let .httpStatus(statusCode, _) = failure else {
            return XCTFail("Expected HTTP status, got \(failure)")
        }
        XCTAssertEqual(statusCode, 409)
        let code = OperationRecoveryMapper.sync(failure).diagnosticCode
        XCTAssertEqual(code, "sync.requestRejected")
        let persisted = SyncQueueFailureEvidence.persistedError(
            diagnosticCode: code,
            disposition: SyncQueueRecoveryPolicy.disposition(for: code),
            underlyingError: failure
        )
        XCTAssertEqual(persisted, "blocked:sync.requestRejected|http=409")
        XCTAssertFalse(persisted.contains("private-response"))
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 1)
        XCTAssertEqual(ScriptedURLProtocol.methods(), ["POST"])
        XCTAssertEqual(ScriptedURLProtocol.paths(), ["/api/v1/config/assets/\(assetID.uuidString.lowercased())/delete"])
        XCTAssertEqual(ScriptedURLProtocol.idempotencyKeys(), [SyncRequestIdentity.mutation(mutation)])
    }

    func testAssetDeleteRetriesKeepOneIdempotencyIdentityThenPreserveFinalStatus() async {
        ScriptedURLProtocol.install([
            .init(statusCode: 503),
            .init(statusCode: 503),
            .init(statusCode: 422, body: #"{"success":false,"error":"do not persist this body"}"#),
        ])
        let service = makeService()
        let mutation = fixtureDeletionRequest

        let failure = await assetDeleteFailure(service, assetID: fixtureAssetID, request: mutation)

        guard case let .httpStatus(statusCode, _) = failure else {
            return XCTFail("Expected final HTTP status, got \(failure)")
        }
        XCTAssertEqual(statusCode, 422)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 3)
        XCTAssertEqual(
            ScriptedURLProtocol.idempotencyKeys(),
            Array(repeating: SyncRequestIdentity.mutation(mutation), count: 3)
        )
        let code = OperationRecoveryMapper.sync(failure).diagnosticCode
        XCTAssertEqual(
            SyncQueueFailureEvidence.persistedError(
                diagnosticCode: code,
                disposition: SyncQueueRecoveryPolicy.disposition(for: code),
                underlyingError: failure
            ),
            "blocked:sync.requestRejected|http=422"
        )
    }

    private var fixtureAssetID: UUID {
        UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    }

    private var fixtureDeletionRequest: AssetMutationRequest {
        AssetMutationRequest(
            deviceID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            operationID: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            vectorClock: "{}"
        )
    }

    private func assetDeleteFailure(
        _ service: NetworkService,
        assetID: UUID,
        request: AssetMutationRequest
    ) async -> NetworkService.NetworkError {
        do {
            try await service.performAssetDeleteFaultInjectionProbe(assetID: assetID, request: request)
            XCTFail("Expected deletion to fail")
            return .decodeFailed
        } catch let failure as NetworkService.NetworkError {
            return failure
        } catch {
            XCTFail("Unexpected failure type: \(type(of: error))")
            return .decodeFailed
        }
    }

    private func makeService(
        retrySleeper: @escaping (UInt64) async throws -> Void = { _ in }
    ) -> NetworkService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        return NetworkService(testingSessionConfiguration: configuration, retrySleeper: retrySleeper)
    }

    private func registerFailure(_ service: NetworkService) async -> NetworkService.NetworkError {
        do {
            try await service.register(username: "fixture-user", password: "fixture-password", inviteCode: "fixture")
            XCTFail("Expected request to fail")
            return .decodeFailed
        } catch let failure as NetworkService.NetworkError {
            return failure
        } catch {
            XCTFail("Unexpected failure type: \(type(of: error))")
            return .decodeFailed
        }
    }

    private func rawRegisterFailure(_ service: NetworkService) async -> Error {
        do {
            try await service.register(username: "fixture-user", password: "fixture-password", inviteCode: "fixture")
            XCTFail("Expected request to fail")
            return NetworkService.NetworkError.decodeFailed
        } catch {
            return error
        }
    }
}

private final class ScriptedURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let headers: [String: String]
        let body: String
        let failureCode: URLError.Code?
        let partialBody: String?

        init(
            statusCode: Int,
            headers: [String: String] = [:],
            body: String = #"{"success":false,"error":"fixture"}"#,
            failureCode: URLError.Code? = nil,
            partialBody: String? = nil
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.failureCode = failureCode
            self.partialBody = partialBody
        }

        static func failure(_ code: URLError.Code, partialBody: String? = nil) -> Stub {
            Stub(statusCode: 200, failureCode: code, partialBody: partialBody)
        }
    }

    private static let lock = NSLock()
    private static var stubs: [Stub] = []
    private(set) static var requestCount = 0
    private static var capturedIdempotencyKeys: [String?] = []
    private static var capturedMethods: [String?] = []
    private static var capturedPaths: [String] = []

    static func install(_ newStubs: [Stub]) {
        lock.lock()
        defer { lock.unlock() }
        stubs = newStubs
        requestCount = 0
        capturedIdempotencyKeys = []
        capturedMethods = []
        capturedPaths = []
    }

    static func reset() {
        install([])
    }

    static func idempotencyKeys() -> [String?] {
        lock.lock()
        defer { lock.unlock() }
        return capturedIdempotencyKeys
    }

    static func methods() -> [String?] {
        lock.lock()
        defer { lock.unlock() }
        return capturedMethods
    }

    static func paths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return capturedPaths
    }

    private static func nextStub(for request: URLRequest) -> Stub? {
        lock.lock()
        defer { lock.unlock() }
        requestCount += 1
        capturedIdempotencyKeys.append(request.value(forHTTPHeaderField: SyncRequestIdentity.header))
        capturedMethods.append(request.httpMethod)
        capturedPaths.append(request.url?.path ?? "")
        guard !stubs.isEmpty else { return nil }
        return stubs.removeFirst()
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.nextStub(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        var headers = stub.headers
        headers["Content-Type"] = "application/json"
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let failureCode = stub.failureCode {
            if let partialBody = stub.partialBody {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(partialBody.utf8))
            }
            client?.urlProtocol(self, didFailWithError: URLError(failureCode))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
