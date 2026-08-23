import XCTest

@MainActor
final class WorkspaceToolCoordinatorTests: XCTestCase {
    private enum StubError: Error { case unused }

    private actor UnusedSFTPOpener: CheckedSFTPConnectionOpening {
        func open(workspaceID: UUID, baseSessionID: BaseSessionID) async throws -> CheckedSFTPConnection {
            throw StubError.unused
        }
    }

    private actor UnusedDockerOperator: CheckedDockerOperating {
        func refresh(binding: CheckedDockerBinding) async throws -> CheckedDockerRefresh { throw StubError.unused }
        func logs(binding: CheckedDockerBinding, containerID: String, tail: UInt32) async throws -> DockerLogsPayload { throw StubError.unused }
        func perform(binding: CheckedDockerBinding, containerID: String, action: CheckedDockerAction) async throws -> DockerActionResultPayload { throw StubError.unused }
    }

    private final class SessionFixture: WorkspaceToolSession {
        let id = UUID()
        var toolTransport: ServerTransportProtocol = .ssh
        var toolHost = "127.0.0.1"
        var toolPort = 22
        var isConnected = true
        var verifiedSessionLease: VerifiedWorkspaceSession?
        var isSFTPConnected = false
        var activeMonitorPanelID: UUID?
        var sftpReject: CheckedSFTPServiceError?
        var dockerReject: CheckedDockerServiceError?
        var sftpDisconnects = 0
        var dockerDisconnects = 0
        var openedSFTP = false
        var startedDocker = false
        var invalidateAfterSFTPOpen = false

        init(baseSessionID: BaseSessionID? = try? BaseSessionID(1)) {
            verifiedSessionLease = baseSessionID.map {
                VerifiedWorkspaceSession(workspaceID: id, baseSessionID: $0, terminalChannelID: nil)
            }
        }

        func configureToolConnection(policy: ConnectionSecurityPolicy, checkedDockerOperator: (any CheckedDockerOperating)?) {}

        func openCheckedSFTP(baseSessionID: BaseSessionID, opener: any CheckedSFTPConnectionOpening) async -> Result<CheckedSFTPConnection, CheckedSFTPServiceError> {
            openedSFTP = true
            if invalidateAfterSFTPOpen { isConnected = false }
            return .success(CheckedSFTPConnection(
                workspaceID: id,
                baseSessionID: baseSessionID,
                sftpSessionID: try! SFTPSessionID("2"),
                homePath: "/home/test"
            ))
        }

        func disconnectSFTP() async { sftpDisconnects += 1 }
        func rejectCheckedSFTP(_ error: CheckedSFTPServiceError) { sftpReject = error }

        func startCheckedDocker(baseSessionID: BaseSessionID) async -> Result<Void, CheckedDockerServiceError> {
            startedDocker = true
            return .success(())
        }

        func disconnectDocker() async { dockerDisconnects += 1 }
        func rejectCheckedDocker(_ error: CheckedDockerServiceError) { dockerReject = error }
        func suspendDockerRefresh() async {}
        func resumeDockerRefresh() async {}
    }

    private final class MonitorFixture: WorkspaceMonitoring {
        var rejectedError: CheckedMonitorServiceError?
        var started = 0
        var lastHost: String?
        var lastPort: Int?
        var disconnected: [UUID] = []
        var onStart: (() -> Void)?

        func startCheckedMonitoring(workspaceID: UUID, baseSessionID: BaseSessionID, name: String, host: String, port: Int) async -> Result<UUID, CheckedMonitorServiceError> {
            started += 1
            lastHost = host
            lastPort = port
            onStart?()
            return .success(UUID())
        }

        func suspendMonitoring(_ panelID: UUID) async {}
        func resumeMonitoring(_ panelID: UUID) async {}
        func disconnect(_ panelID: UUID) async { disconnected.append(panelID) }
        func rejectCheckedStandalone(_ error: CheckedMonitorServiceError) { rejectedError = error }
    }

    private func makeCoordinator(monitor: MonitorFixture) -> WorkspaceToolCoordinator {
        WorkspaceToolCoordinator(
            policy: .checkedRequired,
            sftpOpener: UnusedSFTPOpener(),
            dockerOperator: UnusedDockerOperator(),
            monitoring: monitor
        )
    }

    func testVerifiedWorkspaceStartsSFTPMonitorAndDockerThroughFakes() async {
        let monitor = MonitorFixture()
        let coordinator = makeCoordinator(monitor: monitor)
        let session = SessionFixture()

        let sftpHandled = await coordinator.openSFTPIfHandled(for: session)
        let monitorHandled = await coordinator.startMonitorIfHandled(for: session, name: "fixture")
        let dockerHandled = await coordinator.startDockerIfHandled(for: session)

        XCTAssertTrue(sftpHandled)
        XCTAssertTrue(monitorHandled)
        XCTAssertTrue(dockerHandled)

        XCTAssertTrue(session.openedSFTP)
        XCTAssertTrue(session.startedDocker)
        XCTAssertEqual(monitor.started, 1)
        XCTAssertEqual(monitor.lastHost, session.toolHost)
        XCTAssertEqual(monitor.lastPort, session.toolPort)
        XCTAssertNotNil(session.activeMonitorPanelID)
    }

    func testUnverifiedWorkspaceIsRejectedWithoutOpeningAnyTool() async {
        let monitor = MonitorFixture()
        let coordinator = makeCoordinator(monitor: monitor)
        let session = SessionFixture(baseSessionID: nil)

        _ = await coordinator.openSFTPIfHandled(for: session)
        _ = await coordinator.startMonitorIfHandled(for: session, name: "fixture")
        _ = await coordinator.startDockerIfHandled(for: session)

        XCTAssertEqual(session.sftpReject, .requiresVerifiedSession)
        XCTAssertEqual(session.dockerReject, .requiresVerifiedSession)
        XCTAssertEqual(monitor.rejectedError, .requiresVerifiedSession)
        XCTAssertFalse(session.openedSFTP)
        XCTAssertFalse(session.startedDocker)
        XCTAssertEqual(monitor.started, 0)
    }

    func testLateToolSuccessIsTornDownInsteadOfRevivingInvalidSession() async {
        let monitor = MonitorFixture()
        let coordinator = makeCoordinator(monitor: monitor)
        let session = SessionFixture()
        session.invalidateAfterSFTPOpen = true

        let sftpHandled = await coordinator.openSFTPIfHandled(for: session)
        XCTAssertTrue(sftpHandled)
        XCTAssertEqual(session.sftpDisconnects, 1)

        session.isConnected = true
        monitor.onStart = { session.isConnected = false }
        let monitorHandled = await coordinator.startMonitorIfHandled(for: session, name: "fixture")
        XCTAssertTrue(monitorHandled)
        XCTAssertNil(session.activeMonitorPanelID)
        XCTAssertEqual(monitor.disconnected.count, 1)
    }
}
