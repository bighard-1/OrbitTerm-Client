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

    func testMobileBackgroundLockRequiresAuthenticatedUnlockedAccount() {
        XCTAssertTrue(
            MobileAutoLockPolicy.shouldLockOnBackground(
                isAuthenticated: true,
                wasUnlocked: true
            )
        )
        XCTAssertFalse(
            MobileAutoLockPolicy.shouldLockOnBackground(
                isAuthenticated: false,
                wasUnlocked: true
            )
        )
        XCTAssertFalse(
            MobileAutoLockPolicy.shouldLockOnBackground(
                isAuthenticated: true,
                wasUnlocked: false
            )
        )
    }

    func testProtectedDataLossStillLocksAnUnlockedAccount() {
        XCTAssertTrue(MobileAutoLockPolicy.shouldLockOnProtectedDataLoss(
            isAuthenticated: true, wasUnlocked: true
        ))
        XCTAssertFalse(MobileAutoLockPolicy.shouldLockOnProtectedDataLoss(
            isAuthenticated: false, wasUnlocked: true
        ))
        XCTAssertFalse(MobileAutoLockPolicy.shouldLockOnProtectedDataLoss(
            isAuthenticated: true, wasUnlocked: false
        ))
    }

    func testSecondFactorResumeRequiresSameAccountRecentIntentAndNewUnlock() {
        let start = Date(timeIntervalSince1970: 1_000)
        let intent = PendingSecondFactorResumeIntent(
            serverID: UUID(), accountScopeID: "opaque-account-a", capturedAt: start
        )
        let now = start.addingTimeInterval(MobileSecondFactorResumePolicy.maximumAge - 1)

        XCTAssertTrue(MobileSecondFactorResumePolicy.canResume(
            intent, accountScopeID: "opaque-account-a", now: now,
            isAuthenticated: true, isUnlocked: true
        ))
        XCTAssertFalse(MobileSecondFactorResumePolicy.canResume(
            intent, accountScopeID: "opaque-account-b", now: now,
            isAuthenticated: true, isUnlocked: true
        ))
        XCTAssertFalse(MobileSecondFactorResumePolicy.canResume(
            intent, accountScopeID: "opaque-account-a", now: now,
            isAuthenticated: true, isUnlocked: false
        ))
        XCTAssertFalse(MobileSecondFactorResumePolicy.canResume(
            intent, accountScopeID: "opaque-account-a", now: now,
            isAuthenticated: false, isUnlocked: true
        ))
        XCTAssertFalse(MobileSecondFactorResumePolicy.canResume(
            intent, accountScopeID: "opaque-account-a",
            now: start.addingTimeInterval(MobileSecondFactorResumePolicy.maximumAge + 1),
            isAuthenticated: true, isUnlocked: true
        ))
        XCTAssertFalse(MobileSecondFactorResumePolicy.canResume(
            intent, accountScopeID: "opaque-account-a", now: start.addingTimeInterval(-1),
            isAuthenticated: true, isUnlocked: true
        ))
    }

    func testMobileSecondFactorFocusRequiresCurrentRouteAndConnectedMatchingTerminal() throws {
        let workspaceID = UUID()
        let lease = VerifiedWorkspaceSession(
            workspaceID: workspaceID,
            baseSessionID: try BaseSessionID(1),
            terminalChannelID: try TerminalChannelID("2")
        )

        XCTAssertTrue(MobileSecondFactorSessionFocusPolicy.shouldFocus(
            after: .connected(lease), expectedWorkspaceID: workspaceID,
            routeWasCurrent: true, terminalIsConnected: true
        ))
        XCTAssertFalse(MobileSecondFactorSessionFocusPolicy.shouldFocus(
            after: .connected(lease), expectedWorkspaceID: UUID(),
            routeWasCurrent: true, terminalIsConnected: true
        ))
        XCTAssertFalse(MobileSecondFactorSessionFocusPolicy.shouldFocus(
            after: .connected(lease), expectedWorkspaceID: workspaceID,
            routeWasCurrent: false, terminalIsConnected: true
        ))
        XCTAssertFalse(MobileSecondFactorSessionFocusPolicy.shouldFocus(
            after: .connected(lease), expectedWorkspaceID: workspaceID,
            routeWasCurrent: true, terminalIsConnected: false
        ))
        let nonConnectedOutcomes: [CheckedTerminalConnectionOutcome] = [
            .awaitingSecondFactor, .terminalOpenFailed(lease, .protocolViolation),
            .failed(.protocolViolation), .cancelled
        ]
        for outcome in nonConnectedOutcomes {
            XCTAssertFalse(MobileSecondFactorSessionFocusPolicy.shouldFocus(
                after: outcome, expectedWorkspaceID: workspaceID,
                routeWasCurrent: true, terminalIsConnected: true
            ))
        }
    }

    func testSessionReconnectRequiresUsableRouteAndExplicitIdleState() {
        XCTAssertTrue(
            SessionReconnectPolicy.canReconnect(isNetworkUsable: true, reconnecting: false)
        )
        XCTAssertFalse(
            SessionReconnectPolicy.canReconnect(isNetworkUsable: false, reconnecting: false)
        )
        XCTAssertFalse(
            SessionReconnectPolicy.canReconnect(isNetworkUsable: true, reconnecting: true)
        )
        XCTAssertEqual(
            SessionReconnectPolicy.accessibilityLabel(isNetworkUsable: false, reconnecting: false),
            "等待网络恢复后重新连接"
        )
    }

    func testUserInitiatedConnectionIsNotDroppedBeforeFirstPathCallback() {
        XCTAssertTrue(NetworkRouteState.determining.allowsUserInitiatedConnection)
        XCTAssertTrue(NetworkRouteState.usable.allowsUserInitiatedConnection)
        XCTAssertFalse(NetworkRouteState.unavailable.allowsUserInitiatedConnection)

        XCTAssertFalse(NetworkRouteState.determining.isUsable)
        XCTAssertTrue(NetworkRouteState.usable.isUsable)
    }

    func testLiveSessionRecoveryMarkerPersistsOnlyAConsumableBoolean() throws {
        let suite = "ApplicationOperationLifecyclePolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let marker = LiveSessionRecoveryMarker(defaults: defaults)

        XCTAssertFalse(marker.consumeInterruptedProcessMarker())
        marker.markLiveSessionsPresent()
        XCTAssertTrue(marker.consumeInterruptedProcessMarker())
        XCTAssertFalse(marker.consumeInterruptedProcessMarker())
    }

    func testCredentialMigrationLeaseCannotCrossAccountOrProcessBoundary() {
        var owner = OperationOwner()
        let firstScope = OperationScope.account("scope-a")
        let secondScope = OperationScope.account("scope-b")
        let firstLease = owner.begin(scope: firstScope)

        XCTAssertTrue(owner.owns(firstLease, scope: firstScope))
        _ = owner.begin(scope: secondScope)
        XCTAssertFalse(owner.owns(firstLease, scope: firstScope))

        let freshProcessOwner = OperationOwner()
        XCTAssertFalse(freshProcessOwner.owns(firstLease, scope: firstScope))
    }

    func testKeychainAccessFailureNeverBecomesSignedOutPresentation() {
        let presentation = LocalStorageRecoveryPolicy.keychainFailure(
            .unhandled(-34018)
        )

        XCTAssertEqual(presentation.kind, .secureStorageUnavailable)
        XCTAssertEqual(presentation.actionLabel, "重新检查")
        XCTAssertTrue(presentation.message.contains("不会将此情况视为退出登录"))
    }

    func testSQLiteFailuresHaveDistinctNonDestructiveRecoveryStates() {
        XCTAssertEqual(LocalStorageRecoveryPolicy.sqliteFailureKind(code: 11), .databaseCorrupted)
        XCTAssertEqual(LocalStorageRecoveryPolicy.sqliteFailureKind(code: 13), .storageFull)
        XCTAssertEqual(LocalStorageRecoveryPolicy.sqliteFailureKind(code: 14), .databaseUnavailable)

        for kind in [
            LocalStorageFailureKind.databaseCorrupted,
            .storageFull,
            .databaseUnavailable,
            .migrationInterrupted
        ] {
            let presentation = LocalStorageRecoveryPolicy.presentation(for: kind)
            XCTAssertFalse(presentation.message.isEmpty)
            XCTAssertEqual(presentation.actionLabel, "重新检查")
        }
    }
}
