import Security
import XCTest

final class KeychainDataStoreTests: XCTestCase {
    func testDataProtectionQueryTargetsDataProtectionKeychain() {
        let query = KeychainDataStore.dataProtectionQuery(
            service: "com.orbitterm.tests.keychain",
            account: "primary"
        )

        XCTAssertNotNil(query[kSecClass as String])
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.orbitterm.tests.keychain")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "primary")
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
    }

    func testDataProtectionQueryDoesNotRequireThemeOrSessionState() {
        let query = KeychainDataStore.dataProtectionQuery(
            service: "com.orbitterm.tests.keychain",
            account: "isolation"
        )

        XCTAssertEqual(query.count, 4)
        XCTAssertNil(query["terminalStatus"])
        XCTAssertNil(query["statusText"])
    }
}
