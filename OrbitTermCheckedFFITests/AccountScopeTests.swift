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

    func testFreshActivationAndSignedOutPresentationMustNotFlushDeviceLocalCache() throws {
        XCTAssertFalse(AccountScopeSnapshotPolicy.shouldFlushBeforeScopeChange(previousScope: nil))
        let previous = try XCTUnwrap(AccountScope(username: "previous@example.test"))
        XCTAssertTrue(AccountScopeSnapshotPolicy.shouldFlushBeforeScopeChange(previousScope: previous))
    }

    func testMacQARuntimeIsolationRequiresExactBundleAndExplicitBuildFlag() {
        XCTAssertTrue(MacQARuntimeIsolation.isAllowed(
            bundleIdentifier: "com.orbitterm.matrix.macos", isolationRequested: true
        ))
        XCTAssertFalse(MacQARuntimeIsolation.isAllowed(
            bundleIdentifier: "com.orbitterm.app", isolationRequested: true
        ))
        XCTAssertFalse(MacQARuntimeIsolation.isAllowed(
            bundleIdentifier: "com.orbitterm.matrix.macos", isolationRequested: false
        ))
        XCTAssertFalse(MacQARuntimeIsolation.isEnabled)
        XCTAssertEqual(MacQARuntimeIsolation.applicationDirectoryName, "OrbitTerm")
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
