import XCTest

final class AccountIdentityTests: XCTestCase {
    func testCanonicalUsernameTrimsAndFoldsCase() {
        XCTAssertEqual(
            AccountIdentity.canonicalUsername("  Orbit.User@Example.COM\n"),
            "orbit.user@example.com"
        )
    }
}
