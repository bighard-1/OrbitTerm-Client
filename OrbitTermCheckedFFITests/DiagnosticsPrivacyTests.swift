import XCTest

final class DiagnosticsPrivacyTests: XCTestCase {
    func testEndpointClassificationNeverRetainsHostQueryOrIdentifiers() {
        let endpoint = DiagnosticEndpoint.classify(
            url: "https://alice@example.invalid/api/v1/config/sync/pull?cursor=server-uuid&token=secret"
        )

        XCTAssertEqual(endpoint, .synchronization)
        let line = DiagnosticsPrivacy.exportLine(
            timestamp: "2026-07-28T00:00:00Z",
            method: "GET",
            endpoint: endpoint,
            statusCode: 200,
            latencyMs: 10,
            attempt: 1,
            failure: nil
        )
        XCTAssertFalse(line.contains("example.invalid"))
        XCTAssertFalse(line.contains("server-uuid"))
        XCTAssertFalse(line.contains("secret"))
        XCTAssertTrue(line.contains("endpoint=synchronization"))
    }

    func testUnknownURLExportsOnlyUnknownCategory() {
        let endpoint = DiagnosticEndpoint.classify(
            url: "https://private.example.invalid/api/v1/unknown/asset-123?path=/home/alice"
        )

        XCTAssertEqual(endpoint, .unknown)
    }

    func testFailureClassificationDoesNotExportRawErrorText() {
        XCTAssertEqual(DiagnosticFailureKind.classify("server_5xx_retry"), .serverRetry)
        XCTAssertEqual(DiagnosticFailureKind.classify("URLError"), .transport)
        XCTAssertEqual(DiagnosticFailureKind.classify("server said password=secret"), .unknown)
    }

    func testDiagnosticExportPolicyAcceptsOnlyManagerOwnedUUIDFilenames() {
        let filename = DiagnosticExportFilePolicy.filename(
            for: UUID(uuidString: "F37FF584-B6B3-4B0A-91C7-4B2F15896051")!
        )

        XCTAssertEqual(filename, "orbitterm_diagnostics_f37ff584-b6b3-4b0a-91c7-4b2f15896051.txt")
        XCTAssertTrue(DiagnosticExportFilePolicy.isManagedFilename(filename))
        XCTAssertFalse(DiagnosticExportFilePolicy.isManagedFilename("orbitterm_diagnostics_report.txt"))
        XCTAssertFalse(DiagnosticExportFilePolicy.isManagedFilename("orbitterm_diagnostics_../private.txt"))
        XCTAssertFalse(DiagnosticExportFilePolicy.isManagedFilename("notes.txt"))
    }

    func testDiagnosticExportPolicyExpiresOnlyAfterRetentionBoundary() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(
            DiagnosticExportFilePolicy.isExpired(
                modificationDate: now.addingTimeInterval(-DiagnosticExportFilePolicy.retention + 1),
                now: now
            )
        )
        XCTAssertTrue(
            DiagnosticExportFilePolicy.isExpired(
                modificationDate: now.addingTimeInterval(-DiagnosticExportFilePolicy.retention),
                now: now
            )
        )
    }

    func testSyncEventExportContainsOnlyAllowListedAggregateFields() {
        let line = DiagnosticsPrivacy.syncEventExportLine(.idempotentReplayConfirmed, count: 3)

        XCTAssertEqual(line, "sync_event=idempotent_replay_confirmed count=3")
        XCTAssertFalse(line.contains("account"))
        XCTAssertFalse(line.contains("asset"))
        XCTAssertFalse(line.contains("request"))
        XCTAssertFalse(line.contains("secret"))

        XCTAssertEqual(
            DiagnosticsPrivacy.syncEventExportLine(.deliveryBlocked, count: 2),
            "sync_event=delivery_blocked count=2"
        )
    }
}
