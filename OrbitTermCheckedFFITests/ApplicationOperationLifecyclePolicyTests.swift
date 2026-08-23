import XCTest

final class ApplicationOperationLifecyclePolicyTests: XCTestCase {
    func testActiveUnlockedAccountResumesOnlyOwnedBackgroundWork() {
        let directive = ApplicationOperationLifecyclePolicy.directive(
            for: .becameActive,
            isAuthenticated: true,
            isUnlocked: true
        )

        XCTAssertEqual(directive.syncQueue, .resume)
        XCTAssertTrue(directive.auxiliaryRefreshesActive)
        XCTAssertFalse(directive.closeSessions)
        XCTAssertFalse(directive.clearTransientSensitiveInput)
    }

    func testInactiveAppPausesWorkWithoutClosingVisibleMacWorkspace() {
        let directive = ApplicationOperationLifecyclePolicy.directive(
            for: .becameInactive,
            isAuthenticated: true,
            isUnlocked: true
        )

        XCTAssertEqual(directive.syncQueue, .suspend)
        XCTAssertFalse(directive.auxiliaryRefreshesActive)
        XCTAssertFalse(directive.closeSessions)
        XCTAssertTrue(directive.clearTransientSensitiveInput)
    }

    func testLockSignOutAndExplicitTerminationAlwaysReleaseSessionOwnership() {
        for event in [
            ApplicationOperationLifecycleEvent.accountLocked,
            .accountSignedOut,
            .applicationTerminating
        ] {
            let directive = ApplicationOperationLifecyclePolicy.directive(
                for: event,
                isAuthenticated: true,
                isUnlocked: true
            )

            XCTAssertEqual(directive.syncQueue, .suspend)
            XCTAssertFalse(directive.auxiliaryRefreshesActive)
            XCTAssertTrue(directive.closeSessions)
            XCTAssertTrue(directive.clearTransientSensitiveInput)
        }
    }

    func testBackgroundAndWindowClosePauseWorkWithoutClosingMacSessions() {
        for event in [
            ApplicationOperationLifecycleEvent.becameInactive,
            .enteredBackground,
            .mainWindowClosed
        ] {
            let directive = ApplicationOperationLifecyclePolicy.directive(
                for: event,
                isAuthenticated: true,
                isUnlocked: true
            )

            XCTAssertEqual(directive.syncQueue, .suspend)
            XCTAssertFalse(directive.auxiliaryRefreshesActive)
            XCTAssertFalse(directive.closeSessions)
            XCTAssertTrue(directive.clearTransientSensitiveInput)
        }
    }

    func testAccountSwitchUsesTheSameNoResidualWorkDirectiveAsSignOut() {
        let directive = ApplicationOperationLifecyclePolicy.directive(
            for: .accountSignedOut,
            isAuthenticated: false,
            isUnlocked: false
        )

        XCTAssertEqual(directive.syncQueue, .suspend)
        XCTAssertFalse(directive.auxiliaryRefreshesActive)
        XCTAssertTrue(directive.closeSessions)
        XCTAssertTrue(directive.clearTransientSensitiveInput)
    }

    func testActiveLockedOrSignedOutAccountCannotResumeWork() {
        for state in [(true, false), (false, false)] {
            let directive = ApplicationOperationLifecyclePolicy.directive(
                for: .becameActive,
                isAuthenticated: state.0,
                isUnlocked: state.1
            )

            XCTAssertEqual(directive.syncQueue, .suspend)
            XCTAssertFalse(directive.auxiliaryRefreshesActive)
            XCTAssertFalse(directive.closeSessions)
            XCTAssertTrue(directive.clearTransientSensitiveInput)
        }
    }

    func testInactiveThenActiveRestoresOnlyAnAuthenticatedUnlockedOwner() {
        let paused = ApplicationOperationLifecyclePolicy.directive(
            for: .becameInactive,
            isAuthenticated: true,
            isUnlocked: true
        )
        let resumed = ApplicationOperationLifecyclePolicy.directive(
            for: .becameActive,
            isAuthenticated: true,
            isUnlocked: true
        )

        XCTAssertEqual(paused.syncQueue, .suspend)
        XCTAssertFalse(paused.auxiliaryRefreshesActive)
        XCTAssertEqual(resumed.syncQueue, .resume)
        XCTAssertTrue(resumed.auxiliaryRefreshesActive)
        XCTAssertFalse(resumed.closeSessions)
    }

    func testLockSignOutAndExplicitTerminationInvalidateThePriorOperationOwner() {
        for event in [
            ApplicationOperationLifecycleEvent.accountLocked,
            .accountSignedOut,
            .applicationTerminating
        ] {
            let directive = ApplicationOperationLifecyclePolicy.directive(
                for: event,
                isAuthenticated: true,
                isUnlocked: true
            )
            XCTAssertTrue(directive.closeSessions)

            var owner = OperationOwner()
            let priorLease = owner.begin()
            owner.invalidate()

            XCTAssertFalse(
                owner.owns(priorLease),
                "\\(event) must reject a late completion from its prior owner"
            )
        }
    }
}
