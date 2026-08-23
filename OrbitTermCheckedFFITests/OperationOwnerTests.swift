import XCTest

final class OperationOwnerTests: XCTestCase {
    func testNewLeaseRejectsLateCompletionFromPreviousLease() {
        var owner = OperationOwner()
        let first = owner.begin()
        XCTAssertTrue(owner.owns(first))

        let second = owner.begin()
        XCTAssertFalse(owner.owns(first))
        XCTAssertTrue(owner.owns(second))
    }

    func testInvalidateRejectsCurrentLeaseWithoutCreatingAnotherOwner() {
        var owner = OperationOwner()
        let lease = owner.begin()
        owner.invalidate()

        XCTAssertFalse(owner.owns(lease))
    }

    func testRepeatedReplacementLeavesOnlyNewestCompletionEligibleToPublish() {
        var owner = OperationOwner()
        let first = owner.begin()
        let second = owner.begin()
        let third = owner.begin()

        XCTAssertFalse(owner.owns(first))
        XCTAssertFalse(owner.owns(second))
        XCTAssertTrue(owner.owns(third))
    }

    func testAccountSwitchRejectsLateCompletionFromPriorAccountOwner() {
        var owner = OperationOwner()
        let accountA = owner.begin()
        let accountB = owner.begin()

        XCTAssertFalse(owner.owns(accountA))
        XCTAssertTrue(owner.owns(accountB))
    }

    func testSessionCloseRejectsLateCompletionAfterOwnershipIsInvalidated() {
        var owner = OperationOwner()
        let sessionLease = owner.begin()
        owner.invalidate()

        XCTAssertFalse(owner.owns(sessionLease))
    }

    func testWorkspaceScopeRejectsACompletionForAnotherWorkspace() {
        var owner = OperationOwner()
        let workspaceA = UUID()
        let workspaceB = UUID()
        let lease = owner.begin(scope: .workspace(workspaceA))

        XCTAssertTrue(owner.owns(lease, scope: .workspace(workspaceA)))
        XCTAssertFalse(owner.owns(lease, scope: .workspace(workspaceB)))
    }

    func testAccountReplacementRejectsPriorAccountLeaseEvenWhenWorkFinishesLate() {
        var owner = OperationOwner()
        let prior = owner.begin(scope: .account("account-a"))
        let current = owner.begin(scope: .account("account-b"))

        XCTAssertFalse(owner.owns(prior, scope: .account("account-a")))
        XCTAssertTrue(owner.owns(current, scope: .account("account-b")))
    }

    func testChannelReplacementRejectsBufferedInputFromClosedTerminal() {
        var owner = OperationOwner()
        let oldChannel = owner.begin(scope: .terminalChannel(41))
        owner.invalidate()
        let replacement = owner.begin(scope: .terminalChannel(42))

        XCTAssertFalse(owner.owns(oldChannel, scope: .terminalChannel(41)))
        XCTAssertTrue(owner.owns(replacement, scope: .terminalChannel(42)))
    }

    func testConcurrencyPolicyCapsWorkersWithoutDroppingSingleItemWork() {
        XCTAssertEqual(
            OperationConcurrencyPolicy.workerCount(requested: 99, itemCount: 20, maximum: 3),
            3
        )
        XCTAssertEqual(
            OperationConcurrencyPolicy.workerCount(requested: 0, itemCount: 1, maximum: 3),
            1
        )
        XCTAssertEqual(
            OperationConcurrencyPolicy.workerCount(requested: 3, itemCount: 0, maximum: 3),
            0
        )
        XCTAssertEqual(
            OperationConcurrencyPolicy.workerCount(requested: 1, itemCount: 99, maximum: 3),
            1
        )
        XCTAssertEqual(
            OperationConcurrencyPolicy.workerCount(requested: 3, itemCount: 2, maximum: 3),
            2
        )
    }

    func testPageOwnerRejectsLateCompletionAfterAccountSwitch() {
        var owner = PageOperationOwner()
        let accountA = OperationScope.account("opaque-account-a")
        let accountB = OperationScope.account("opaque-account-b")
        let first = owner.begin(scope: accountA, timeout: 30)

        owner.cancel(.accountChanged)
        let replacement = owner.begin(scope: accountB, timeout: 30)

        XCTAssertFalse(owner.accepts(first, scope: accountA))
        XCTAssertTrue(owner.accepts(replacement, scope: accountB))
        XCTAssertNil(owner.cancellationReason)
    }

    func testPageOwnerRejectsLateCallbackAfterLockAndSignOut() {
        var owner = PageOperationOwner()
        let account = OperationScope.account("opaque-account")
        let lockedLease = owner.begin(scope: account, timeout: 30)
        owner.cancel(.accountLocked)

        XCTAssertFalse(owner.accepts(lockedLease, scope: account))
        XCTAssertEqual(owner.cancellationReason, .accountLocked)

        let signedOutLease = owner.begin(scope: account, timeout: 30)
        owner.cancel(.accountSignedOut)

        XCTAssertFalse(owner.accepts(signedOutLease, scope: account))
        XCTAssertEqual(owner.cancellationReason, .accountSignedOut)
    }

    func testPageOwnerRejectsLateCallbackAfterPageDisappears() {
        var owner = PageOperationOwner()
        let lease = owner.begin(scope: .anonymous, timeout: 30)

        owner.cancel(.pageDisappeared)

        XCTAssertFalse(owner.accepts(lease, scope: .anonymous))
        XCTAssertEqual(owner.cancellationReason, .pageDisappeared)
    }

    func testPageOwnerDeadlineMakesSlowOperationIneligibleToPublish() {
        var owner = PageOperationOwner()
        let lease = owner.begin(scope: .anonymous, timeout: 2)

        XCTAssertTrue(owner.accepts(lease, scope: .anonymous, now: lease.deadline.addingTimeInterval(-0.1)))
        XCTAssertTrue(owner.timeoutReached(lease, now: lease.deadline))
        XCTAssertFalse(owner.accepts(lease, scope: .anonymous, now: lease.deadline))
    }

    func testPageOwnerAllowsOnlyFreshOperationAfterLock() {
        var owner = PageOperationOwner()
        let scope = OperationScope.account("opaque-account")
        let interrupted = owner.begin(scope: scope, timeout: 30)

        owner.cancel(.accountLocked)
        let replacement = owner.begin(scope: scope, timeout: 30)

        XCTAssertFalse(owner.accepts(interrupted, scope: scope))
        XCTAssertTrue(owner.accepts(replacement, scope: scope))
        XCTAssertNil(owner.cancellationReason)
    }

    func testPageOwnerRejectsExplicitlyCancelledPageResult() {
        var owner = PageOperationOwner()
        let lease = owner.begin(scope: .anonymous, timeout: 30)

        owner.cancel(.userCancelled)

        XCTAssertFalse(owner.accepts(lease, scope: .anonymous))
        XCTAssertEqual(owner.cancellationReason, .userCancelled)
    }
}
