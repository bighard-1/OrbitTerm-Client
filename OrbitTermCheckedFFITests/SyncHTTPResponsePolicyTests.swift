import XCTest

final class SyncHTTPResponsePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_220_800) // 2026-09-01T00:00:00Z

    func testStatusClassesHaveStableRecoverySemantics() {
        XCTAssertEqual(SyncHTTPResponsePolicy.disposition(statusCode: 401), .authenticationExpired)
        XCTAssertEqual(SyncHTTPResponsePolicy.disposition(statusCode: 408), .retryable)
        XCTAssertEqual(SyncHTTPResponsePolicy.disposition(statusCode: 429), .retryable)
        XCTAssertEqual(SyncHTTPResponsePolicy.disposition(statusCode: 503), .retryable)
        XCTAssertEqual(SyncHTTPResponsePolicy.disposition(statusCode: 409), .permanentRejection)
        XCTAssertEqual(SyncHTTPResponsePolicy.disposition(statusCode: 422), .permanentRejection)
        XCTAssertEqual(SyncHTTPResponsePolicy.disposition(statusCode: 302), .protocolViolation)
    }

    func testRetryAfterAcceptsDeltaAndHTTPDateAndClampsUntrustedValues() {
        XCTAssertEqual(SyncHTTPResponsePolicy.retryAfterSeconds("120", now: now), 120)
        XCTAssertEqual(
            SyncHTTPResponsePolicy.retryAfterSeconds("Tue, 01 Sep 2026 00:10:00 GMT", now: now),
            600
        )
        XCTAssertEqual(SyncHTTPResponsePolicy.retryAfterSeconds("999999", now: now), 3_600)
        XCTAssertNil(SyncHTTPResponsePolicy.retryAfterSeconds("0", now: now))
        XCTAssertNil(SyncHTTPResponsePolicy.retryAfterSeconds("not-a-date", now: now))
    }
}
