import XCTest

final class SFTPUploadQueueControllerTests: XCTestCase {
    @MainActor
    func testLeavingDuringAnUncooperativeUploadStopsTheRemainingQueue() async throws {
        let started = expectation(description: "second upload waiting")
        let gate = UploadQueueTestGate(started: started)
        let controller = SFTPUploadQueueController()
        var attempted: [String] = []
        var completed: [String] = []
        let task = try XCTUnwrap(controller.start(urls: urls("first", "slow", "queued"), canContinue: { true }) { url in
            attempted.append(url.lastPathComponent)
            if url.lastPathComponent == "slow" { await gate.hold() }
            if !Task.isCancelled { completed.append(url.lastPathComponent) }
        })
        await fulfillment(of: [started], timeout: 2)
        controller.abandon()
        XCTAssertTrue(task.isCancelled)
        await gate.release()
        await task.value
        XCTAssertEqual(attempted, ["first", "slow"])
        XCTAssertEqual(completed, ["first"])
        XCTAssertFalse(controller.isRunning)
    }

    @MainActor
    func testChangedDestinationStopsLaterFilesEvenWithoutAViewCallback() async throws {
        let started = expectation(description: "first upload waiting")
        let gate = UploadQueueTestGate(started: started)
        let controller = SFTPUploadQueueController()
        var targetIsCurrent = true
        var attempted: [String] = []
        let task = try XCTUnwrap(controller.start(urls: urls("first", "wrong-target"), canContinue: { targetIsCurrent }) { url in
            attempted.append(url.lastPathComponent)
            await gate.hold()
        })
        await fulfillment(of: [started], timeout: 2)
        targetIsCurrent = false
        await gate.release()
        await task.value
        XCTAssertEqual(attempted, ["first"])
        XCTAssertFalse(controller.isRunning)
    }

    @MainActor
    func testOldCompletionCannotClearTheNextQueuesOwnership() async throws {
        let oldStarted = expectation(description: "old queue waiting")
        let nextStarted = expectation(description: "next queue waiting")
        let old = UploadQueueTestGate(started: oldStarted)
        let next = UploadQueueTestGate(started: nextStarted)
        let controller = SFTPUploadQueueController()
        let oldTask = try XCTUnwrap(controller.start(urls: urls("old", "must-not-start"), canContinue: { true }) { url in
            XCTAssertEqual(url.lastPathComponent, "old")
            await old.hold()
        })
        await fulfillment(of: [oldStarted], timeout: 2)
        controller.abandon()
        let nextTask = try XCTUnwrap(controller.start(urls: urls("next"), canContinue: { true }) { _ in await next.hold() })
        await fulfillment(of: [nextStarted], timeout: 2)
        await old.release()
        await oldTask.value
        XCTAssertTrue(controller.isRunning)
        XCTAssertFalse(nextTask.isCancelled)
        XCTAssertNil(controller.start(urls: urls("overlap"), canContinue: { true }) { _ in XCTFail("Duplicate queue") })
        await next.release()
        await nextTask.value
        XCTAssertFalse(controller.isRunning)
    }

    @MainActor
    func testImmediateAbandonAndInvalidSelectionCannotStartUploads() async throws {
        let controller = SFTPUploadQueueController()
        XCTAssertNil(controller.start(urls: [], canContinue: { true }) { _ in XCTFail("Empty selection") })
        XCTAssertNil(controller.start(urls: urls("stale"), canContinue: { false }) { _ in XCTFail("Stale picker") })
        let task = try XCTUnwrap(controller.start(urls: urls("first", "second"), canContinue: { true }) { _ in
            XCTFail("Abandoned before scheduling")
        })
        controller.abandon()
        await task.value
        XCTAssertFalse(controller.isRunning)
    }

    private func urls(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/virtual/\($0)") } }
}

private actor UploadQueueTestGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func hold() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
