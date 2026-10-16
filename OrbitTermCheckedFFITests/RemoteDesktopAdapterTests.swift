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

    func testRemoteDesktopFocusLossReleasesHeldModifiersAndPointerButtons() {
        XCTAssertEqual(
            RemoteDesktopInputReleasePlan.modifierScancodes(for: [.shift, .command]),
            [0x2A, 0x15B]
        )
        XCTAssertEqual(
            RemoteDesktopInputReleasePlan.pointerReleaseActions(for: [5, 1, 3]),
            [2, 4, 6]
        )
        XCTAssertTrue(RemoteDesktopInputReleasePlan.modifierScancodes(for: []).isEmpty)
        XCTAssertTrue(RemoteDesktopInputReleasePlan.pointerReleaseActions(for: []).isEmpty)
    }

    func testClosedSessionCannotBeRevivedByLateCallbacks() {
        var machine = RemoteDesktopSessionStateMachine()
        XCTAssertTrue(machine.transition(to: .authenticating))
        XCTAssertTrue(machine.transition(to: .connected))
        XCTAssertTrue(machine.transition(to: .closed))
        XCTAssertFalse(machine.transition(to: .connected))
        XCTAssertEqual(machine.phase, .closed)
    }

    func testControllerPublishesPreEngineFailureAndRetryReopensSavedTarget() async throws {
        let adapter = FailingRemoteDesktopAdapter(failure: .authenticationFailed)
        let controller = RemoteDesktopSessionController(adapter: adapter)
        var phases: [RemoteDesktopSessionPhase] = []
        controller.onUpdate = { phases.append($0.phase) }
        let server = ServerEntry(
            name: "RDP test",
            host: "rdp.example.test",
            port: 3389,
            username: "test-user",
            authMethod: .password,
            transport: .rdp
        )

        do {
            try await controller.connect(to: server)
            XCTFail("The injected adapter must fail before creating an engine session")
        } catch {
            XCTAssertEqual(error as? RemoteDesktopFailureKind, .authenticationFailed)
        }
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertEqual(controller.failureMessage, "远程桌面凭据无效或无权登录。")
        XCTAssertEqual(adapter.openCount, 1)
        XCTAssertEqual(phases, [.starting, .failed])

        await controller.reconnect()
        XCTAssertEqual(adapter.openCount, 2)
        XCTAssertEqual(controller.phase, .failed)

        await controller.disconnect()
        XCTAssertEqual(controller.phase, .disconnected)
        XCTAssertNil(controller.failureMessage)
        await controller.reconnect()
        XCTAssertEqual(adapter.openCount, 3)
        XCTAssertEqual(controller.phase, .failed)
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

@MainActor
private final class FailingRemoteDesktopAdapter: RemoteDesktopEngineAdapter {
    let capability: RemoteDesktopRuntimeCapability = .available
    private let failure: RemoteDesktopFailureKind
    private(set) var openCount = 0

    init(failure: RemoteDesktopFailureKind) {
        self.failure = failure
    }

    func open(profile: RemoteDesktopConnectionProfile) async throws -> any RemoteDesktopEngineSession {
        _ = profile
        openCount += 1
        throw failure
    }
}
