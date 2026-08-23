import XCTest

@MainActor
final class AccountScopedServiceLifecycleTests: XCTestCase {
    private final class ServiceFixture: AccountScopedPresentationService {
        var activatedUsernames: [String] = []
        var deactivateCount = 0

        func activateAccount(username: String) { activatedUsernames.append(username) }
        func deactivateAccount() { deactivateCount += 1 }
    }

    func testAccountSwitchActivatesOnlyTheNewAccountScope() {
        let sync = ServiceFixture()
        let diagnostics = ServiceFixture()

        AccountScopedServiceLifecycle.reconcile(
            isAuthenticated: true,
            username: "first@example.invalid",
            services: [sync, diagnostics]
        )
        AccountScopedServiceLifecycle.reconcile(
            isAuthenticated: true,
            username: "second@example.invalid",
            services: [sync, diagnostics]
        )

        XCTAssertEqual(sync.activatedUsernames, ["first@example.invalid", "second@example.invalid"])
        XCTAssertEqual(diagnostics.activatedUsernames, ["first@example.invalid", "second@example.invalid"])
        XCTAssertEqual(sync.deactivateCount, 0)
    }

    func testLogoutDeactivatesSyncAndDiagnosticsSoConflictRecoveryCannotLeak() {
        let sync = ServiceFixture()
        let diagnostics = ServiceFixture()

        AccountScopedServiceLifecycle.reconcile(
            isAuthenticated: false,
            username: "",
            services: [sync, diagnostics]
        )

        XCTAssertEqual(sync.deactivateCount, 1)
        XCTAssertEqual(diagnostics.deactivateCount, 1)
        XCTAssertTrue(sync.activatedUsernames.isEmpty)
        XCTAssertTrue(diagnostics.activatedUsernames.isEmpty)
    }
}
