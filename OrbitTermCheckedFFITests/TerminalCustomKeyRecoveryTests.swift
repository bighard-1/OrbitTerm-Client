import Foundation
import XCTest

final class TerminalCustomKeyRecoveryTests: XCTestCase {
    private let rescueVector = "T1RLRVlSUzEAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobV7JDvv5jZdHTowVJ+qDBVEPiFP+34k6U0hjG2eK6ZCJ3pI4Pz/06jSQjcsuK9TmuTSdBmtTvVBGxrOosc7Vws4nyJ7t/KsvD9TD8Ue9kzy0Iap/kSbb6ooz3OKk6wZ1qOLHmJW4G8tPYIEnNy7yfNTK/8kUReqKZ3BQyNyBa31eAE2MslIa61A=="
    func testRescueIndependentAndroidVectorPreservesMalformedUTF16AndIsNotImportable() throws {
        let bytes = try XCTUnwrap(Data(base64Encoded: rescueVector))
        let snapshot = try TerminalCustomKeyRecoveryPackage.openRescue(bytes, password: "rescue-passphrase-2026")
        XCTAssertEqual(snapshot.platform, 2)
        XCTAssertEqual(snapshot.account, String(repeating: "a", count: 64))
        XCTAssertEqual(snapshot.sources[2]?.suffix(2), Data([0xd8, 0]))
        XCTAssertEqual(snapshot.sources[4], Data([1]))
        XCTAssertEqual(try snapshot.encoded().base64EncodedString(), "AmFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEDAgAAABAAaQBuAHYAYQBsAGkAZNgAAwAAABYAWwB7AHQAcgB1AG4AYwBhAHQAZQBkBAAAAAEB")
        XCTAssertThrowsError(try TerminalCustomKeyRecoveryPackage.open(bytes, password: "rescue-passphrase-2026"))
        XCTAssertThrowsError(try TerminalCustomKeyRecoveryPackage.openRescue(vector().swift, password: vector().password))
    }
    func testRescueRawAppleBytesRoundTripWithoutRepairOrNormalization() throws {
        let snapshot = TerminalCustomKeyRecoveryPackage.RescueSnapshot(platform: 1, account: String(repeating: "b", count: 64), sources: [1: Data([0xff, 0, 0xc0, 0x80])])
        let a = try TerminalCustomKeyRecoveryPackage.sealRescue(snapshot, password: "rescue-passphrase-2026")
        let b = try TerminalCustomKeyRecoveryPackage.sealRescue(snapshot, password: "rescue-passphrase-2026")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(try TerminalCustomKeyRecoveryPackage.openRescue(a, password: "rescue-passphrase-2026"), snapshot)
    }
    func testRescueTamperTruncationOversizeAndUnknownSourcesFailClosed() throws {
        let bytes = try XCTUnwrap(Data(base64Encoded: rescueVector))
        for offset in [0, 8, 24, 36, bytes.count - 1] {
            var bad = bytes; bad[offset] ^= 1
            XCTAssertThrowsError(try TerminalCustomKeyRecoveryPackage.openRescue(bad, password: "rescue-passphrase-2026"))
        }
        XCTAssertThrowsError(try TerminalCustomKeyRecoveryPackage.openRescue(bytes, password: "wrong-passphrase-2026"))
        let snapshot = TerminalCustomKeyRecoveryPackage.RescueSnapshot(platform: 1, account: String(repeating: "b", count: 64), sources: [1: Data()])
        let raw = try snapshot.encoded()
        XCTAssertThrowsError(try TerminalCustomKeyRecoveryPackage.RescueSnapshot.decode(raw + Data([0])))
        XCTAssertThrowsError(try TerminalCustomKeyRecoveryPackage.RescueSnapshot.decode(Data(raw.dropLast())))
        XCTAssertThrowsError(try TerminalCustomKeyRecoveryPackage.RescueSnapshot(platform: 1, account: snapshot.account, sources: [2: Data()]).encoded())
        XCTAssertThrowsError(try TerminalCustomKeyRecoveryPackage.RescueSnapshot(platform: 1, account: snapshot.account, sources: [1: Data(repeating: 0, count: 4 * 1024 * 1024 + 1)]).encoded())
    }
    private struct Vector: Decodable {
        let password: String
        let envelope: TerminalCustomKeyEnvelope
        let salt: Data
        let nonce: Data
        let swift: Data
        let kotlin: Data
    }
    private func vector() throws -> Vector {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: root.appendingPathComponent("shared/mobile-contracts/key-recovery-v1-vector.json")))
    }
    func testIndependentKnownAnswerAndBothNativeWireOrders() throws {
        let v = try vector()
        XCTAssertEqual(try TerminalCustomKeyRecoveryPackage.seal(v.envelope, password: v.password, salt: v.salt, nonce: v.nonce), v.swift)
        for bytes in [v.swift, v.kotlin] {
            XCTAssertEqual(try TerminalCustomKeyRecoveryPackage.open(bytes, password: v.password), v.envelope)
        }
    }
    func testHeaderSaltNonceCipherAndTagTamperingAllFailClosed() throws {
        let v = try vector()
        for offset in [0, 8, 24, 36, v.swift.count - 1] {
            var bytes = v.swift; bytes[offset] ^= 1
            XCTAssertThrowsError(try TerminalCustomKeyRecoveryPackage.open(bytes, password: v.password))
        }
        XCTAssertThrowsError(try TerminalCustomKeyRecoveryPackage.open(v.swift, password: v.password + " "))
        for bytes in [Data(), v.swift.prefix(52), v.swift + Data([0]), Data(repeating: 0, count: TerminalCustomKeyRecoveryPackage.maxBytes + 1)] {
            XCTAssertThrowsError(try TerminalCustomKeyRecoveryPackage.open(Data(bytes), password: v.password))
        }
    }
    func testRandomizedExportsPreserveTombstonesAndConflicts() throws {
        let v = try vector(), first = v.envelope.revisions[0]
        let envelope = TerminalCustomKeyEnvelope.v1([first, .init(id: first.id,
            clock: ["bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb": 1], value: nil)])
        let a = try TerminalCustomKeyRecoveryPackage.seal(envelope, password: v.password)
        let b = try TerminalCustomKeyRecoveryPackage.seal(envelope, password: v.password)
        XCTAssertNotEqual(a, b)
        XCTAssertNil(a.range(of: Data("测试".utf8)))
        XCTAssertEqual(try TerminalCustomKeyRecoveryPackage.open(a, password: v.password), envelope)
    }
    func testPasswordBoundsAreUnicodeAwareAndNeverTrimmed() {
        for pass in ["123456789012", String(repeating: "😀", count: 64), "            a"] {
            XCTAssertTrue(TerminalCustomKeyRecoveryPackage.validPassword(pass))
        }
        for pass in ["12345678901", String(repeating: "😀", count: 65), "            ", "123456789012\n"] {
            XCTAssertFalse(TerminalCustomKeyRecoveryPackage.validPassword(pass))
        }
    }
}
