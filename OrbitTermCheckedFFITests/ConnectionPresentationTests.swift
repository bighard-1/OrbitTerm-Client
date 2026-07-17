import XCTest

final class ConnectionPresentationTests: XCTestCase {
    private func map(lease: Bool = false, channel: Bool = false, connected: Bool = false, awaiting: Bool = false, phase: ConnectionPresentationPhase? = nil) -> ConnectionPresentation {
        ConnectionPresentationMapper.map(.init(hasVerifiedLease: lease, hasTerminalChannel: channel, isConnected: connected, isAwaitingHostKeyDecision: awaiting, explicitPhase: phase))
    }

    func testPresentationMapsReliableConnectionInputs() {
        XCTAssertEqual(map().phase, .idle)
        XCTAssertEqual(map(phase: .connecting).phase, .connecting)
        XCTAssertEqual(map(awaiting: true).phase, .awaitingHostKeyDecision)
        XCTAssertEqual(map(lease: true).phase, .openingTerminal)
        XCTAssertEqual(map(lease: true, channel: true, connected: true).phase, .connected)
        XCTAssertEqual(map(phase: .blocked).phase, .blocked)
        XCTAssertEqual(map(phase: .failed).phase, .failed)
        XCTAssertEqual(map(phase: .cancelled).phase, .cancelled)
    }

    func testPresentationHasAccessibleTextAndDistinctBlockedRole() {
        let blocked = map(phase: .blocked)
        let connected = map(lease: true, channel: true, connected: true)
        XCTAssertFalse(blocked.label.isEmpty); XCTAssertFalse(blocked.systemImage.isEmpty)
        XCTAssertNotEqual(blocked.label, connected.label)
        XCTAssertEqual(blocked.semanticRole, .blocked)
    }

    func testTypedHostKeySnapshotAndAdapterPriority() {
        let blocked = ConnectionPresentationAdapter.input(.init(hasVerifiedSessionLease: true, hasTerminalChannel: true, isSessionUsable: true, isConnectOperationInProgress: true, wasConnectionLost: false, hostKey: .blocked(.changed)))
        XCTAssertEqual(ConnectionPresentationMapper.map(blocked).phase, .blocked)
        let awaiting = ConnectionPresentationAdapter.input(.init(hasVerifiedSessionLease: false, hasTerminalChannel: false, isSessionUsable: false, isConnectOperationInProgress: true, wasConnectionLost: false, hostKey: .awaitingDecision))
        XCTAssertEqual(ConnectionPresentationMapper.map(awaiting).phase, .awaitingHostKeyDecision)
        let lost = ConnectionPresentationAdapter.input(.init(hasVerifiedSessionLease: true, hasTerminalChannel: true, isSessionUsable: false, isConnectOperationInProgress: false, wasConnectionLost: true, hostKey: .none))
        XCTAssertEqual(ConnectionPresentationMapper.map(lost).phase, .disconnected)
    }

    func testCheckedSSHFactoryUsesOnlyReliableLeaseAndChannelFields() {
        XCTAssertEqual(ConnectionPresentationAdapter.checkedSSH(hasVerifiedSessionLease: false, hasTerminalChannel: false, isSessionUsable: false).phase, .idle)
        XCTAssertEqual(ConnectionPresentationAdapter.checkedSSH(hasVerifiedSessionLease: true, hasTerminalChannel: false, isSessionUsable: false).phase, .openingTerminal)
        XCTAssertEqual(ConnectionPresentationAdapter.checkedSSH(hasVerifiedSessionLease: true, hasTerminalChannel: true, isSessionUsable: true).phase, .connected)
    }
}
