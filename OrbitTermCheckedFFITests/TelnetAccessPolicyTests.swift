import XCTest

@MainActor
final class TelnetAccessPolicyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "TelnetAccessPolicyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultIsDisabledAndIgnoresLegacyPreference() {
        defaults.set(true, forKey: "orbitterm.enable.telnet")
        let policy = TelnetAccessPolicy(userDefaults: defaults)

        XCTAssertFalse(policy.isEnabled)
        XCTAssertEqual(policy.decision(for: target()), .preferenceDisabled)
    }

    func testEnabledTargetRequiresConfirmationBeforeItIsAllowed() {
        let policy = TelnetAccessPolicy(userDefaults: defaults)
        let target = target()

        policy.setEnabled(true)
        XCTAssertEqual(policy.decision(for: target), .requiresConfirmation)

        policy.confirm(target)
        XCTAssertEqual(policy.decision(for: target), .allowed)
    }

    func testHostOrPortChangeRequiresNewConfirmation() {
        let policy = TelnetAccessPolicy(userDefaults: defaults)
        let original = target(host: "Router.Local", port: 23)
        policy.setEnabled(true)
        policy.confirm(original)

        XCTAssertEqual(policy.decision(for: target(host: "router.local", port: 23)), .allowed)
        XCTAssertEqual(policy.decision(for: target(host: "router-new.local", port: 23)), .requiresConfirmation)
        XCTAssertEqual(policy.decision(for: target(host: "router.local", port: 2323)), .requiresConfirmation)
    }

    func testDisablingClearsAllTargetConfirmations() {
        let policy = TelnetAccessPolicy(userDefaults: defaults)
        let target = target()
        policy.setEnabled(true)
        policy.confirm(target)
        XCTAssertEqual(policy.decision(for: target), .allowed)

        policy.setEnabled(false)
        XCTAssertEqual(policy.decision(for: target), .preferenceDisabled)

        policy.setEnabled(true)
        XCTAssertEqual(policy.decision(for: target), .requiresConfirmation)
    }

    func testConfirmationCannotBeRecordedWhileDisabled() {
        let policy = TelnetAccessPolicy(userDefaults: defaults)
        let target = target()

        policy.confirm(target)
        policy.setEnabled(true)

        XCTAssertEqual(policy.decision(for: target), .requiresConfirmation)
    }

    func testReenableClearsConfirmationsEvenAfterAnInterruptedDisableCleanup() {
        let policy = TelnetAccessPolicy(userDefaults: defaults)
        let target = target()
        policy.setEnabled(true)
        policy.confirm(target)
        XCTAssertEqual(policy.decision(for: target), .allowed)

        defaults.set(false, forKey: TelnetAccessPolicy.enabledStorageKey)
        policy.setEnabled(true)

        XCTAssertEqual(policy.decision(for: target), .requiresConfirmation)
    }

    private func target(
        id: UUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        host: String = "router.local",
        port: Int = 23
    ) -> TelnetTargetIdentity {
        TelnetTargetIdentity(serverID: id, host: host, port: port)
    }
}
