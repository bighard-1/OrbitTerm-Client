import Foundation
import XCTest

final class TerminalCustomKeyContractTests: XCTestCase {
    private let actor = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let other = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private let id = "11111111-1111-1111-1111-111111111111"
    private struct Vectors: Decodable {
        struct Case: Decodable { let left: [Int]; let right: [Int]; let expected: [Int]; let active: Int }
        let revisions: [TerminalCustomKeyRevision]
        let cases: [Case]
    }
    private func vectors() throws -> Vectors {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: root.appendingPathComponent("shared/mobile-contracts/custom-key-merge-vectors.json")))
    }
    private func value(_ payload: String = "a") -> TerminalCustomKeyValue {
        .init(label: "键", payload: payload, section: "common", order: 0)
    }

    func testConflictReviewHasStableOrderAndDoesNotGuessFromIdenticalValues() throws {
        let a = TerminalCustomKeyRevision(id: id, clock: [actor: 1], value: value())
        let b = TerminalCustomKeyRevision(id: id, clock: [other: 1], value: value())
        let first = try TerminalCustomKeyContract.conflicts(.v1([b, a, a]))
        XCTAssertEqual(first, try TerminalCustomKeyContract.conflicts(.v1([a, b])))
        XCTAssertEqual(first[0].revisions.count, 2)
        XCTAssertTrue(try TerminalCustomKeyContract.active(.v1([a, b])).isEmpty)
        XCTAssertTrue(try TerminalCustomKeyContract.conflicts(.v1([a, a])).isEmpty)
    }

    func testReviewedKeepOrDeleteDominatesEveryBranchAndReplay() throws {
        let a = TerminalCustomKeyRevision(id: id, clock: [actor: 1], value: value())
        for otherValue: TerminalCustomKeyValue? in [value("b"), nil] {
            let b = TerminalCustomKeyRevision(id: id, clock: [other: 2], value: otherValue)
            let before = TerminalCustomKeyEnvelope.v1([a, b])
            let review = try XCTUnwrap(TerminalCustomKeyContract.conflicts(before).first)
            for keep: TerminalCustomKeyRevision? in [a, nil] {
                let after = try TerminalCustomKeyContract.resolving(before, observed: review, keeping: keep, actor: actor)
                XCTAssertEqual(after.revisions[0].clock, [actor: 2, other: 2])
                XCTAssertEqual(after.revisions[0].value, keep?.value)
                XCTAssertEqual(after, try TerminalCustomKeyContract.merge(after, before))
                XCTAssertTrue(try TerminalCustomKeyContract.conflicts(after).isEmpty)
            }
        }
    }

    func testStalePartialAndInventedConflictChoicesAreRejected() throws {
        let a = TerminalCustomKeyRevision(id: id, clock: [actor: 1], value: value())
        let b = TerminalCustomKeyRevision(id: id, clock: [other: 1], value: nil)
        let before = TerminalCustomKeyEnvelope.v1([a, b])
        let review = try XCTUnwrap(TerminalCustomKeyContract.conflicts(before).first)
        let late = TerminalCustomKeyRevision(id: id, clock: ["cccccccc-cccc-cccc-cccc-cccccccccccc": 1], value: value("c"))
        XCTAssertThrowsError(try TerminalCustomKeyContract.resolving(.v1([a, b, late]), observed: review, keeping: a, actor: actor))
        XCTAssertThrowsError(try TerminalCustomKeyContract.resolving(before, observed: .init(id: id, revisions: [a]), keeping: a, actor: actor))
        for choice in [late, b] {
            XCTAssertThrowsError(try TerminalCustomKeyContract.resolving(before, observed: review, keeping: choice, actor: actor))
        }
        let after = try TerminalCustomKeyContract.resolving(before, observed: review, keeping: a, actor: actor)
        XCTAssertThrowsError(try TerminalCustomKeyContract.resolving(after, observed: review, keeping: nil, actor: actor))
    }

    func testSharedMergeVectorsAndWireRoundTrips() throws {
        let vectors = try vectors()
        for row in vectors.cases {
            let left = TerminalCustomKeyEnvelope.v1(row.left.map { vectors.revisions[$0] })
            let right = TerminalCustomKeyEnvelope.v1(row.right.map { vectors.revisions[$0] })
            let result = try TerminalCustomKeyContract.merge(left, right)
            XCTAssertEqual(result.revisions.count, row.expected.count)
            for expected in row.expected { XCTAssertTrue(result.revisions.contains(vectors.revisions[expected])) }
            XCTAssertEqual(try TerminalCustomKeyContract.active(result).count, row.active)
            XCTAssertEqual(result, try TerminalCustomKeyContract.merge(right, left))
            XCTAssertEqual(result, try TerminalCustomKeyContract.merge(result, result))
            XCTAssertEqual(result, try TerminalCustomKeyContract.decode(TerminalCustomKeyContract.encode(result)))
        }
    }

    func testMergeAssociativityForCausalAndConcurrentHistories() throws {
        let rows = try vectors().revisions
        // Exclude the intentional same-clock edit/delete collision (1 vs 3).
        for a in [0, 2, 3, 4, 5] { for b in [0, 2, 3, 4, 5] { for c in [0, 2, 3, 4, 5] {
            let x = TerminalCustomKeyEnvelope.v1([rows[a]]), y = TerminalCustomKeyEnvelope.v1([rows[b]]), z = TerminalCustomKeyEnvelope.v1([rows[c]])
            XCTAssertEqual(try TerminalCustomKeyContract.merge(TerminalCustomKeyContract.merge(x, y), z),
                           try TerminalCustomKeyContract.merge(x, TerminalCustomKeyContract.merge(y, z)))
        } } }
    }

    func testExplicitResolutionDominatesBothBranchesAndStaleReplay() throws {
        let rows = try vectors().revisions
        let conflict = try TerminalCustomKeyContract.merge(.v1([rows[3]]), .v1([rows[2]]))
        let deleted = try TerminalCustomKeyContract.replacing(conflict, id: id, actor: actor, value: nil)
        XCTAssertEqual(deleted.revisions[0].clock, [actor: 3, other: 1])
        XCTAssertTrue(try TerminalCustomKeyContract.active(TerminalCustomKeyContract.merge(deleted, conflict)).isEmpty)
        let restored = try TerminalCustomKeyContract.replacing(deleted, id: id, actor: other, value: value())
        XCTAssertEqual(try TerminalCustomKeyContract.active(restored).count, 1)
        XCTAssertEqual(restored, try TerminalCustomKeyContract.merge(restored, deleted))
    }

    func testStrictSchemaVersionsAndInvalidInputsAreBlocked() throws {
        let valid = try TerminalCustomKeyContract.encode(.v1([.init(id: id, clock: [actor: 1], value: value())]))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        let integerSpelling = String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "\"version\":1", with: "\"version\":1e0")
        XCTAssertEqual(try TerminalCustomKeyContract.decode(Data(integerSpelling.utf8)), try TerminalCustomKeyContract.decode(valid))
        let text = String(decoding: valid, as: UTF8.self)
        for duplicate in [text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1"),
                          text.replacingOccurrences(of: "\"id\":", with: "\"\\u0069d\":\"\(id)\",\"id\":")] {
            XCTAssertThrowsError(try TerminalCustomKeyContract.decode(Data(duplicate.utf8)))
        }
        XCTAssertFalse(TerminalCustomKeyContract.validID(id + "\n"))
        try TerminalCustomKeyContract.validate(.v1([.init(id: id, clock: [actor: 1],
            value: .init(label: String(repeating: "😀", count: 16), payload: "a", section: "common", order: 0))]))
        for label in [String(repeating: "😀", count: 17), " ", "a\n", "a\u{2028}"] {
            XCTAssertThrowsError(try TerminalCustomKeyContract.validate(.v1([.init(id: id, clock: [actor: 1],
                value: .init(label: label, payload: "a", section: "common", order: 0))])))
        }
        for field in ["version", "payloadSyntaxVersion"] {
            var future = root; future[field] = 2
            XCTAssertThrowsError(try TerminalCustomKeyContract.decode(JSONSerialization.data(withJSONObject: future)))
        }
        root["future"] = "must not disappear"
        XCTAssertThrowsError(try TerminalCustomKeyContract.decode(JSONSerialization.data(withJSONObject: root)))
        let deleted = try TerminalCustomKeyContract.encode(.v1([.init(id: id, clock: [actor: 1], value: nil)]))
        XCTAssertTrue(String(decoding: deleted, as: UTF8.self).contains("\"value\":null"))
        XCTAssertThrowsError(try TerminalCustomKeyContract.decode(Data(String(decoding: deleted, as: UTF8.self).replacingOccurrences(of: ",\"value\":null", with: "").utf8)))
        for payload in ["", "\\x+F", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try TerminalCustomKeyContract.validate(.v1([.init(id: id, clock: [actor: 1], value: value(payload))])))
        }
        XCTAssertThrowsError(try TerminalCustomKeyContract.decode(Data(repeating: 32, count: TerminalCustomKeyContract.maxBytes + 1)))
    }

    func testRevisionCollisionUsesExactUnicodeBytes() throws {
        let left = TerminalCustomKeyEnvelope.v1([.init(id: id, clock: [actor: 1], value: value("é"))])
        let right = TerminalCustomKeyEnvelope.v1([.init(id: id, clock: [actor: 1], value: value("e\u{301}"))])
        XCTAssertThrowsError(try TerminalCustomKeyContract.merge(left, right))
        XCTAssertThrowsError(try TerminalCustomKeyContract.merge(left, .v1([.init(id: id, clock: [actor: 1], value: nil)])))
        let concurrent = try TerminalCustomKeyContract.merge(left, .v1([.init(id: id, clock: [other: 1], value: value("e\u{301}"))]))
        XCTAssertEqual(concurrent.revisions.count, 2)
        XCTAssertTrue(try TerminalCustomKeyContract.active(concurrent).isEmpty)
    }

    func testBoundsNeverTruncateKeysConflictsOrTombstones() throws {
        func identifier(_ n: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", n) }
        let keys = (0..<65).map { TerminalCustomKeyRevision(id: identifier($0), clock: [actor: 1], value: value()) }
        XCTAssertThrowsError(try TerminalCustomKeyContract.merge(.v1(Array(keys.prefix(64))), .v1([keys[64]])))
        let tombstones = (0..<257).map { TerminalCustomKeyRevision(id: identifier($0), clock: [actor: 1], value: nil) }
        XCTAssertThrowsError(try TerminalCustomKeyContract.merge(.v1(Array(tombstones.prefix(256))), .v1([tombstones[256]])))
        let conflicts = (0..<9).map { TerminalCustomKeyRevision(id: id, clock: [identifier($0): 1], value: value()) }
        XCTAssertThrowsError(try TerminalCustomKeyContract.merge(.v1(Array(conflicts.prefix(8))), .v1([conflicts[8]])))
        let saturated = TerminalCustomKeyEnvelope.v1([.init(id: id, clock: [actor: TerminalCustomKeyContract.maxCounter], value: nil)])
        XCTAssertThrowsError(try TerminalCustomKeyContract.replacing(saturated, id: id, actor: actor, value: value()))
        XCTAssertThrowsError(try TerminalCustomKeyContract.validate(.v1([.init(id: id, clock: [:], value: nil)])))
    }
}
