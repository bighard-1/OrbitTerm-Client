import XCTest

@MainActor
final class WorkspacePresentationCoordinatorTests: XCTestCase {
    private final class SessionFixture: WorkspaceSessionPresenting {
        let id: UUID
        let presentationServerID: UUID

        init(id: UUID = UUID(), serverID: UUID = UUID()) {
            self.id = id
            presentationServerID = serverID
        }
    }

    func testCoordinatorActivatesAndFindsOnlyTheRequestedFixture() {
        let coordinator = WorkspacePresentationCoordinator<SessionFixture>()
        let first = SessionFixture()
        let second = SessionFixture()

        XCTAssertNil(coordinator.appendAndActivate(first))
        XCTAssertEqual(coordinator.activeSession?.id, first.id)

        XCTAssertEqual(coordinator.appendAndActivate(second)?.id, first.id)
        XCTAssertEqual(coordinator.activeSession?.id, second.id)
        XCTAssertEqual(coordinator.session(forServerID: first.presentationServerID)?.id, first.id)
        XCTAssertNil(coordinator.session(forServerID: UUID()))
    }

    func testInvalidOrRepeatedActivationDoesNotChangePresentation() {
        let coordinator = WorkspacePresentationCoordinator<SessionFixture>()
        let first = SessionFixture()
        let second = SessionFixture()
        _ = coordinator.appendAndActivate(first)
        _ = coordinator.appendAndActivate(second)

        XCTAssertNil(coordinator.activate(second.id))
        XCTAssertNil(coordinator.activate(UUID()))
        XCTAssertEqual(coordinator.activeSession?.id, second.id)
        XCTAssertEqual(coordinator.activate(first.id)?.id, second.id)
        XCTAssertEqual(coordinator.activeSession?.id, first.id)
    }

    func testRemovingActiveFixtureSelectsFirstRemainingFixture() {
        let coordinator = WorkspacePresentationCoordinator<SessionFixture>()
        let first = SessionFixture()
        let second = SessionFixture()
        _ = coordinator.appendAndActivate(first)
        _ = coordinator.appendAndActivate(second)

        XCTAssertTrue(coordinator.remove(second.id))
        XCTAssertEqual(coordinator.activeSession?.id, first.id)
        XCTAssertFalse(coordinator.remove(UUID()))
        XCTAssertEqual(coordinator.tabs.map(\.id), [first.id])
    }

    func testSftpInitialPathPrefersTheAuthenticatedUsersHome() {
        XCTAssertEqual(
            SFTPInitialPathPolicy.preferredPath(username: " alice "),
            "/home/alice"
        )
        XCTAssertEqual(SFTPInitialPathPolicy.preferredPath(username: "root"), "/root")
        XCTAssertEqual(SFTPInitialPathPolicy.preferredPath(username: "bad/name"), "/")
    }
}
