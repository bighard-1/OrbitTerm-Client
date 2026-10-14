import Foundation
import XCTest

final class TerminalCustomKeyRepairPreviewTests: XCTestCase {
    private let account = String(repeating: "a", count: 64)
    private let actor = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let id = "11111111-1111-1111-1111-111111111111"

    private func document(_ rows: [Any], extraEnvelope: [String: Any] = [:]) throws -> Data {
        var envelope: [String: Any] = ["kind": "terminal_custom_keys", "version": 1,
            "payloadSyntaxVersion": 1, "revisions": rows]
        extraEnvelope.forEach { envelope[$0] = $1 }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "account": account,
            "actor": actor, "envelope": envelope], options: [.sortedKeys])
    }
    private func row(id: String? = nil, label: String = "键", payload: String = "private-command\\r",
                     section: String = "common", clock: [String: Any]? = nil) -> [String: Any] {
        ["id": id ?? self.id, "clock": clock ?? [actor: 1],
         "value": ["label": label, "payload": payload, "section": section, "order": 0]]
    }

    func testEnumeratesRowsWithSanitizedSummariesAndNoPayloadMaterial() throws {
        let data = try document([
            row(),
            row(id: "bad-id", label: "bad\u{202E}name", payload: "\\x+F", section: "Future"),
            "not-an-object",
        ])
        let preview = TerminalCustomKeyRepairPreviewParser.appleDocument(data, rescueAccount: account)
        XCTAssertNil(preview.blockedReason)
        XCTAssertEqual(preview.items.count, 3)
        XCTAssertEqual(preview.items[0].disposition, .keepUnchanged)
        XCTAssertEqual(preview.items[0].idSummary, "…11111111")
        XCTAssertEqual(preview.items[0].payloadUTF8Bytes, "private-command\\r".utf8.count)
        XCTAssertFalse(String(describing: preview).contains("private-command"))
        XCTAssertEqual(preview.items[1].disposition, .manualCorrectionRequired)
        XCTAssertTrue(preview.items[1].issues.contains(.invalidID))
        XCTAssertTrue(preview.items[1].issues.contains(.invalidPayload))
        XCTAssertTrue(preview.items[1].issues.contains(.invalidSection))
        XCTAssertEqual(preview.items[1].labelSummary, "bad\\u{202E}name")
        XCTAssertEqual(preview.items[2].disposition, .cannotInterpret)
    }

    func testMetadataCollisionAndCapacityAreExplicitWithoutSelectingWinners() throws {
        let conflicting = [row(), row(label: "另一个")]
        let collision = TerminalCustomKeyRepairPreviewParser.appleDocument(
            try document(conflicting, extraEnvelope: ["future": true]), rescueAccount: account)
        XCTAssertTrue(collision.documentIssues.contains(.invalidDocumentMetadata))
        XCTAssertTrue(collision.items.allSatisfy { $0.issues.contains(.revisionCollision) })

        let rows = (0...64).map { index in
            row(id: String(format: "00000000-0000-0000-0000-%012d", index))
        }
        let capacity = TerminalCustomKeyRepairPreviewParser.appleDocument(try document(rows), rescueAccount: account)
        XCTAssertEqual(capacity.items.count, 65)
        XCTAssertTrue(capacity.items.allSatisfy { $0.disposition == .capacitySelectionRequired })
        XCTAssertTrue(capacity.items.allSatisfy { $0.issues.contains(.capacitySelectionRequired) })
    }

    func testMalformedAmbiguousWrongRootAndOversizedCollectionsBlockWholePreview() throws {
        let malformed = TerminalCustomKeyRepairPreviewParser.appleDocument(Data("{".utf8), rescueAccount: account)
        XCTAssertEqual(malformed.blockedReason, .malformedOrAmbiguous)
        let duplicate = Data("{\"envelope\":{\"revisions\":[]},\"envelope\":{\"revisions\":[]}}".utf8)
        XCTAssertEqual(TerminalCustomKeyRepairPreviewParser.appleDocument(duplicate, rescueAccount: account).blockedReason,
                       .malformedOrAmbiguous)
        XCTAssertEqual(TerminalCustomKeyRepairPreviewParser.appleDocument(Data("[]".utf8), rescueAccount: account).blockedReason,
                       .rootNotEnumerable)
        let oversized = try document(Array(repeating: NSNull(), count: 257))
        let preview = TerminalCustomKeyRepairPreviewParser.appleDocument(oversized, rescueAccount: account)
        XCTAssertEqual(preview.blockedReason, .tooManyItems)
        XCTAssertTrue(preview.items.isEmpty)
    }

    func testDecisionPlanRequiresEveryChoiceAndNeverRetainsReplacementPayload() throws {
        let preview = TerminalCustomKeyRepairPreviewParser.appleDocument(try document([
            row(), row(id: "22222222-2222-2222-2222-222222222222", label: "bad\u{202E}name", section: "Future"),
        ]), rescueAccount: account)
        let incomplete = TerminalCustomKeyRepairDecisionPlanner.make(preview: preview, sessionToken: "session-a",
            decisions: [0: .init(choice: .keep, correction: nil)])
        XCTAssertFalse(incomplete.isReadyForSecondConfirmation)
        XCTAssertTrue(incomplete.issues.contains(.missingDecision(1)))

        let correction = TerminalCustomKeyRepairCorrection(label: "修正键", payload: "replacement-command\\r", section: "symbols")
        let complete = TerminalCustomKeyRepairDecisionPlanner.make(preview: preview, sessionToken: "session-a", decisions: [
            0: .init(choice: .keep, correction: nil), 1: .init(choice: .correct, correction: correction),
        ])
        XCTAssertTrue(complete.isReadyForSecondConfirmation)
        XCTAssertEqual(complete.keptCount, 1)
        XCTAssertEqual(complete.correctedCount, 1)
        XCTAssertEqual(complete.activeIdentityCount, 2)
        XCTAssertEqual(complete.rows[1].payloadUTF8Bytes, correction.payload.utf8.count)
        XCTAssertFalse(String(describing: complete).contains("replacement-command"))
        XCTAssertEqual(complete.confirmationBaseline?.count, 16)
        XCTAssertNotEqual(complete.confirmationBaseline,
            TerminalCustomKeyRepairDecisionPlanner.make(preview: preview, sessionToken: "session-b", decisions: [
                0: .init(choice: .keep, correction: nil), 1: .init(choice: .correct, correction: correction),
            ]).confirmationBaseline)
    }

    func testDecisionPlanRejectsUnsafeKeepInvalidCorrectionAndGlobalBlockers() throws {
        let preview = TerminalCustomKeyRepairPreviewParser.appleDocument(try document([
            row(id: "bad-id", section: "Future"), "not-an-object",
        ]), rescueAccount: account)
        let invalid = TerminalCustomKeyRepairDecisionPlanner.make(preview: preview, sessionToken: "session", decisions: [
            0: .init(choice: .keep, correction: nil),
            1: .init(choice: .correct, correction: .init(label: "键", payload: "\\r", section: "common")),
        ])
        XCTAssertTrue(invalid.issues.contains(.invalidChoice(0)))
        XCTAssertTrue(invalid.issues.contains(.invalidCorrection(1)))
        XCTAssertNil(invalid.confirmationBaseline)

        let safe = TerminalCustomKeyRepairPreviewParser.appleDocument(try document([row()]), rescueAccount: account)
        let protected = TerminalCustomKeyRepairPreview(source: safe.source, blockedReason: nil,
            documentIssues: [], items: safe.items, protectedSourcePresent: true)
        let blocked = TerminalCustomKeyRepairDecisionPlanner.make(preview: protected, sessionToken: "session",
            decisions: [0: .init(choice: .exclude, correction: nil)])
        XCTAssertTrue(blocked.issues.contains(.protectedSourceConflict))
        XCTAssertTrue(blocked.requiresDataLossAcknowledgement)
        XCTAssertFalse(blocked.isReadyForSecondConfirmation)
    }

    func testCapacityDecisionsMustExplicitlyReduceCandidateSet() throws {
        let rows = (0...64).map { index in row(id: String(format: "00000000-0000-0000-0000-%012d", index)) }
        let preview = TerminalCustomKeyRepairPreviewParser.appleDocument(try document(rows), rescueAccount: account)
        var decisions = Dictionary(uniqueKeysWithValues: preview.items.map {
            ($0.index, TerminalCustomKeyRepairDecision(choice: .keep, correction: nil))
        })
        XCTAssertTrue(TerminalCustomKeyRepairDecisionPlanner.make(preview: preview, sessionToken: "session", decisions: decisions)
            .issues.contains(.capacityExceeded(65)))
        decisions[64] = .init(choice: .capacityExclude, correction: nil)
        let reduced = TerminalCustomKeyRepairDecisionPlanner.make(preview: preview, sessionToken: "session", decisions: decisions)
        XCTAssertTrue(reduced.isReadyForSecondConfirmation)
        XCTAssertEqual(reduced.activeIdentityCount, 64)
        XCTAssertEqual(reduced.excludedCount, 1)
        XCTAssertTrue(reduced.requiresDataLossAcknowledgement)
    }
}
