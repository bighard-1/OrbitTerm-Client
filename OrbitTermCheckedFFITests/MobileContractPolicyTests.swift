import Foundation
import XCTest

final class MobileContractPolicyTests: XCTestCase {
    func testReservedCustomKeyRoutingNeverUsesAssetIdentity() throws {
        struct Vector: Decodable { let plaintext: String; let reserved: Bool }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/mobile-contracts/custom-key-routing-vectors.json"))
        for row in try JSONDecoder().decode([Vector].self, from: data) {
            let bytes = Data(row.plaintext.utf8)
            XCTAssertEqual(TerminalCustomKeySyncCompatibility.routing(bytes, assetID: nil), row.reserved ? .deferred : .unrelated)
            for identity in ["", "not-an-id", "11111111-2222-3333-4444-555555555555"] {
                XCTAssertEqual(TerminalCustomKeySyncCompatibility.routing(bytes, assetID: identity), row.reserved ? .invalidAssetIdentity : .unrelated)
            }
        }
    }

    private struct Vectors: Decodable {
        struct Payload: Decodable { let input: String; let bytes: [UInt8]? }
        struct Contact: Decodable { let input: String; let email: String? }
        let payloads: [Payload]
        let contacts: [Contact]
    }

    private func vectors() throws -> Vectors {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/mobile-contracts/v1-vectors.json"))
        return try JSONDecoder().decode(Vectors.self, from: data)
    }

    func testSharedPayloadVectors() throws {
        for vector in try vectors().payloads {
            XCTAssertEqual(TerminalCustomKeyPayload.decode(vector.input), vector.bytes)
        }
    }

    func testDecodedByteLimits() {
        XCTAssertEqual(TerminalCustomKeyPayload.decode(String(repeating: "\\xFF", count: 64))?.count, 64)
        XCTAssertEqual(TerminalCustomKeyPayload.decode(String(repeating: "😀", count: 16))?.count, 64)
        XCTAssertNil(TerminalCustomKeyPayload.decode(String(repeating: "😀", count: 17)))
        XCTAssertNil(TerminalCustomKeyPayload.decode(String(repeating: "a", count: 65)))
        XCTAssertNil(TerminalCustomKeyPayload.decode(String(repeating: "\\xFF", count: 65)))
    }

    func testSharedContactVectors() throws {
        for vector in try vectors().contacts {
            XCTAssertEqual(AdministratorContactPolicy.validatedEmail(vector.input), vector.email)
            XCTAssertEqual(AdministratorContactPolicy.emailOrDefault(vector.input), vector.email ?? AdministratorContactPolicy.defaultEmail)
        }
    }

    func testMailURLHasOneRecipientAndNoInjectedFields() throws {
        let email = "Support+mobile@example.com"
        let url = try XCTUnwrap(AdministratorContactPolicy.mailURL(email: email))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "mailto")
        XCTAssertEqual(components.path, email)
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "subject", value: AdministratorContactPolicy.subject)])
        XCTAssertNil(components.fragment)
        XCTAssertNil(AdministratorContactPolicy.mailURL(email: "a@example.com?bcc=b@example.com"))
    }

    func testContactBoundsAndOfflineFallback() {
        XCTAssertNil(AdministratorContactPolicy.validatedEmail(String(repeating: "a", count: 65) + "@example.com"))
        XCTAssertNil(AdministratorContactPolicy.validatedEmail("a@" + String(repeating: "b", count: 64) + ".com"))
        XCTAssertEqual(AdministratorContactPolicy.emailOrDefault(nil), "orbitterm@163.com")
    }
}
