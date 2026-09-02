import XCTest

final class AccountScopeTests: XCTestCase {
    func testCanonicalVariantsShareOneOpaqueStorageNamespace() throws {
        let first = try XCTUnwrap(AccountScope(username: "  Admin@OrbitTerm.com "))
        let second = try XCTUnwrap(AccountScope(username: "admin@orbitterm.com"))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.storageIdentifier, second.storageIdentifier)
        XCTAssertFalse(first.storageKey("orbitterm.servers.v2").contains(first.canonicalUsername))
    }

    func testDifferentAccountsNeverShareStorageKeysOrDatabaseNames() throws {
        let first = try XCTUnwrap(AccountScope(username: "first@example.com"))
        let second = try XCTUnwrap(AccountScope(username: "second@example.com"))

        XCTAssertNotEqual(first.storageIdentifier, second.storageIdentifier)
        XCTAssertNotEqual(
            first.storageKey("orbitterm.sync.shadow.v4"),
            second.storageKey("orbitterm.sync.shadow.v4")
        )
        XCTAssertNotEqual(
            first.databaseFileName("snippets", pathExtension: "sqlite"),
            second.databaseFileName("snippets", pathExtension: "sqlite")
        )
    }

    func testBlankAccountCannotCreateStorageNamespace() {
        XCTAssertNil(AccountScope(username: "  \n "))
    }

    func testLegacyMigrationReservationCanOnlyResumeForItsOpaqueOwner() throws {
        let first = try XCTUnwrap(AccountScope(username: "first@example.invalid"))
        let second = try XCTUnwrap(AccountScope(username: "second@example.invalid"))

        XCTAssertTrue(
            AccountMigrationReservationPolicy.canResume(
                migrationCompleted: false,
                reservedOwner: nil,
                requestingScope: first.storageIdentifier
            )
        )
        XCTAssertTrue(
            AccountMigrationReservationPolicy.canResume(
                migrationCompleted: false,
                reservedOwner: first.storageIdentifier,
                requestingScope: first.storageIdentifier
            )
        )
        XCTAssertFalse(
            AccountMigrationReservationPolicy.canResume(
                migrationCompleted: false,
                reservedOwner: first.storageIdentifier,
                requestingScope: second.storageIdentifier
            )
        )
        XCTAssertFalse(
            AccountMigrationReservationPolicy.canResume(
                migrationCompleted: true,
                reservedOwner: first.storageIdentifier,
                requestingScope: first.storageIdentifier
            )
        )
    }
}
