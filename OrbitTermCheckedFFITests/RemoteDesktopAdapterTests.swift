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

    func testNativeRuntimeProbeUsesPinnedABIAndVersion() {
        let runtime = FreeRDPRuntimeProbe.current()
        XCTAssertEqual(runtime.abiVersion, 2)
        XCTAssertEqual(runtime.expectedVersion, "3.26.0")

        switch runtime.status {
        case .available:
            XCTAssertEqual(runtime.actualVersion, runtime.expectedVersion)
        case .versionMismatch:
            XCTAssertNotNil(runtime.actualVersion)
            XCTAssertNotEqual(runtime.actualVersion, runtime.expectedVersion)
        case .unavailable:
            XCTAssertNil(runtime.actualVersion)
        }
    }

    func testFrameBufferRejectsMalformedFramesAndCreatesBGRAImage() throws {
        XCTAssertThrowsError(
            try RemoteDesktopFrame(width: 2, height: 2, stride: 4, bgraBytes: Data(repeating: 0, count: 16))
        ) { error in
            XCTAssertEqual(error as? RemoteDesktopFrameError, .invalidStride)
        }

        let frame = try RemoteDesktopFrame(
            width: 2,
            height: 2,
            stride: 8,
            bgraBytes: Data(repeating: 0x7F, count: 16)
        )
        let image = try frame.makeImage()
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.bytesPerRow, 8)
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
