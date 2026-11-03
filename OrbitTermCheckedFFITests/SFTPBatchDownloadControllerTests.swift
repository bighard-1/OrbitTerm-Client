import XCTest

final class SFTPBatchDownloadControllerTests: XCTestCase {
    @MainActor
    func testToolbarCancellationRetainsBusyStateUntilWorkerCleanupFinishes() async throws {
        let started = expectation(description: "download started")
        let gate = WorkstationBatchTestGate(started: started)
        let controller = SFTPBatchDownloadController()
        let task = try XCTUnwrap(controller.start(items: [file("complete.bin"), file("slow.bin")]) {
            await gate.run($0)
        })
        await fulfillment(of: [started], timeout: 2)
        controller.requestCancellation()
        controller.requestCancellation()
        XCTAssertTrue(task.isCancelled)
        XCTAssertTrue(controller.state.isRunning)
        XCTAssertTrue(controller.state.isCancelling)
        XCTAssertFalse(controller.state.isResultPresented)
        XCTAssertNil(controller.start(items: [file("overlap.bin")]) { _ in
            XCTFail("Stopping worker must still own this controller")
            return .init(summary: .init(), downloadedURLs: [])
        })
        await gate.complete(.init(
            summary: .init(succeeded: ["complete.bin"], failed: ["slow.bin": "传输已取消"]),
            downloadedURLs: [URL(fileURLWithPath: "/virtual/complete.bin")]
        ))
        await task.value
        XCTAssertFalse(controller.state.isRunning)
        XCTAssertFalse(controller.state.isCancelling)
        XCTAssertTrue(controller.state.isResultPresented)
        XCTAssertTrue(controller.state.resultMessage.contains("成功 1 项，取消 1 项，失败 0 项"))
        XCTAssertTrue(controller.state.completedDownloadURLs.isEmpty)
    }

    @MainActor
    func testOldSessionCompletionCannotReplaceTheNewSessionsBatch() async throws {
        let oldStarted = expectation(description: "old session started")
        let nextStarted = expectation(description: "new session started")
        let old = WorkstationBatchTestGate(started: oldStarted)
        let next = WorkstationBatchTestGate(started: nextStarted)
        let controller = SFTPBatchDownloadController()
        let oldTask = try XCTUnwrap(controller.start(items: [file("old.bin")]) { await old.run($0) })
        await fulfillment(of: [oldStarted], timeout: 2)
        controller.abandon()
        XCTAssertTrue(oldTask.isCancelled)
        let nextTask = try XCTUnwrap(controller.start(items: [file("next.bin")]) { await next.run($0) })
        await fulfillment(of: [nextStarted], timeout: 2)
        await old.complete(.init(summary: .init(succeeded: ["old.bin"]), downloadedURLs: [
            URL(fileURLWithPath: "/virtual/old.bin")
        ]))
        await oldTask.value
        XCTAssertTrue(controller.state.isRunning)
        XCTAssertFalse(controller.state.isResultPresented)
        XCTAssertFalse(nextTask.isCancelled)
        let nextURL = URL(fileURLWithPath: "/virtual/next.bin")
        await next.complete(.init(summary: .init(succeeded: ["next.bin"]), downloadedURLs: [nextURL]))
        await nextTask.value
        XCTAssertTrue(controller.state.isResultPresented)
        XCTAssertTrue(controller.takeCompletedDownloads().isEmpty)
        controller.dismissResult()
        XCTAssertEqual(controller.takeCompletedDownloads(), [nextURL])
    }

    @MainActor
    func testImmediateCancellationDoesNotStartTheOperation() async throws {
        let controller = SFTPBatchDownloadController()
        let task = try XCTUnwrap(controller.start(items: [file("first.bin"), file("second.bin")]) { _ in
            XCTFail("Cancellation before scheduling must not enter the transfer operation")
            return .init(summary: .init(), downloadedURLs: [])
        })
        controller.requestCancellation()
        await task.value
        XCTAssertTrue(controller.state.resultMessage.contains("成功 0 项，取消 2 项，失败 0 项"))
        XCTAssertFalse(controller.state.isRunning)
    }

    @MainActor
    func testCancellationKeepsRealCleanupFailureVisible() async throws {
        let started = expectation(description: "worker started")
        let gate = WorkstationBatchTestGate(started: started)
        let controller = SFTPBatchDownloadController()
        let task = try XCTUnwrap(controller.start(items: [file("partial.bin")]) { await gate.run($0) })
        await fulfillment(of: [started], timeout: 2)
        controller.requestCancellation()
        await gate.complete(.init(summary: .init(failed: [
            "partial.bin": "下载目标清理失败，请检查并删除本次部分文件"
        ]), downloadedURLs: []))
        await task.value
        XCTAssertTrue(controller.state.resultMessage.contains("失败 1 项"))
        XCTAssertTrue(controller.state.resultMessage.contains("目标清理失败"))
        controller.abandon()
        XCTAssertFalse(controller.state.isResultPresented)
        XCTAssertTrue(controller.state.completedDownloadURLs.isEmpty)
    }

    @MainActor
    func testOnlySnapshotFilesAreDownloadedAndDirectoriesAloneDoNotStartWork() async throws {
        let controller = SFTPBatchDownloadController()
        let directory = FileItem(name: "directory", size: 0, permissions: "drwx------", permissionsOctal: 0o040700, modifiedAtUnix: 0)
        XCTAssertNil(controller.start(items: [directory]) { _ in
            XCTFail("Directories must not enter the file-only batch downloader")
            return .init(summary: .init(), downloadedURLs: [])
        })
        var input = [file("snapshot.bin"), directory]
        let task = try XCTUnwrap(controller.start(items: input) { received in
            XCTAssertEqual(received.map(\.name), ["snapshot.bin"])
            return .init(summary: .init(succeeded: received.map(\.name)), downloadedURLs: [])
        })
        input.removeAll()
        await task.value
        XCTAssertTrue(controller.state.resultMessage.contains("下载完成：共 1 项"))
    }

    private func file(_ name: String) -> FileItem {
        FileItem(name: name, size: 4096, permissions: "-rw-------", permissionsOctal: 0o100600, modifiedAtUnix: 0)
    }
}

private actor WorkstationBatchTestGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<BatchDownloadResult, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func run(_ items: [FileItem]) async -> BatchDownloadResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func complete(_ result: BatchDownloadResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
