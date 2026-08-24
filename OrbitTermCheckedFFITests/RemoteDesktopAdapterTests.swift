import XCTest

@MainActor
final class RemoteDesktopAdapterTests: XCTestCase {
    func testProfilesAllowWindowsAndLinuxButRejectMacOSTargets() throws {
        XCTAssertNoThrow(try profile(target: .windows))
        XCTAssertNoThrow(try profile(target: .linux))
        XCTAssertThrowsError(try profile(target: .macOS)) { error in
            XCTAssertEqual(error as? RemoteDesktopFailureKind, .invalidTarget)
        }
    }

    func testDeferredAdapterFailsClosedWithoutSshFallback() async throws {
        let adapter = DeferredFreeRDPAdapter()
        XCTAssertEqual(adapter.capability, .unavailable)

        do {
            _ = try await adapter.open(profile: profile(target: .windows))
            XCTFail("Unavailable FreeRDP runtime must not open a session")
        } catch {
            XCTAssertEqual(error as? RemoteDesktopFailureKind, .engineUnavailable)
        }
    }

    func testClosedSessionCannotBeRevivedByLateCallbacks() {
        var machine = RemoteDesktopSessionStateMachine()
        XCTAssertTrue(machine.transition(to: .authenticating))
        XCTAssertTrue(machine.transition(to: .connected))
        XCTAssertTrue(machine.transition(to: .closed))
        XCTAssertFalse(machine.transition(to: .connected))
        XCTAssertEqual(machine.phase, .closed)
    }

    private func profile(target: RemoteDesktopTargetPlatform) throws -> RemoteDesktopConnectionProfile {
        try RemoteDesktopConnectionProfile(
            assetID: UUID(),
            host: "rdp.example.test",
            port: 3389,
            targetPlatform: target,
            credentialID: UUID()
        )
    }
}
