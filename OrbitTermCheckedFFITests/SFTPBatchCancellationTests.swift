import XCTest

final class SFTPBatchCancellationTests: XCTestCase {
    func testCompletedFilesRequireResultDismissalAndExplicitExport() {
        var state = SFTPBrowserBatchState()
        let complete = URL(fileURLWithPath: "/virtual/complete.bin")
        state.beginDownload(total: 1)
        state.finishBatch(message: "下载完成", downloadedURLs: [complete])
        XCTAssertTrue(state.isResultPresented)
        XCTAssertTrue(state.takeCompletedDownloads().isEmpty)
        XCTAssertEqual(state.completedDownloadURLs, [complete])
        state.isResultPresented = false
        XCTAssertEqual(state.takeCompletedDownloads(), [complete])
        XCTAssertTrue(state.takeCompletedDownloads().isEmpty)
    }

    func testCancelledMixedBatchDoesNotOfferExportAndAbandonmentRevokesPendingFiles() {
        var state = SFTPBrowserBatchState()
        let complete = URL(fileURLWithPath: "/virtual/complete.bin")
        state.beginDownload(total: 2)
        state.finishBatch(message: "已停止", downloadedURLs: [complete], wasCancelled: true)
        state.isResultPresented = false
        XCTAssertTrue(state.takeCompletedDownloads().isEmpty)
        state.beginDownload(total: 1)
        state.finishBatch(message: "完成", downloadedURLs: [complete])
        state.cancelBatch()
        XCTAssertFalse(state.isResultPresented)
        XCTAssertTrue(state.takeCompletedDownloads().isEmpty)
    }

    func testNextBatchCannotExportPreviousCompletedFiles() {
        var state = SFTPBrowserBatchState()
        state.finishBatch(message: "完成", downloadedURLs: [URL(fileURLWithPath: "/virtual/old.bin")])
        state.beginDownload(total: 1)
        XCTAssertTrue(state.completedDownloadURLs.isEmpty)
        XCTAssertTrue(state.takeCompletedDownloads().isEmpty)
    }

    func testOrdinaryCancellationDoesNotCreateContradictoryFailureStatus() {
        let summary = BatchOperationSummary(succeeded: ["complete.bin"], failed: ["slow.bin": "传输已取消"])
        let status = summary.downloadStatusText(wasCancelled: true)
        XCTAssertTrue(status.contains("已停止"))
        XCTAssertTrue(status.contains("成功 1 项，取消 1 项"))
        XCTAssertFalse(status.contains("失败"))
    }

    func testCleanupFailureStillCreatesActionableFailureStatusAfterCancellation() {
        let summary = BatchOperationSummary(succeeded: [], failed: [
            "a.bin": "传输已取消", "z.bin": "下载目标清理失败，请检查并删除本次部分文件"
        ])
        let status = summary.downloadStatusText(wasCancelled: true)
        XCTAssertTrue(status.contains("失败 1 项"))
        XCTAssertTrue(status.contains("目标清理失败"))
    }

    func testCancellationRetainsBusySelectionUntilWorkerCleanupAcknowledgesExit() {
        var state = SFTPBrowserBatchState()
        state.selectedIDs = ["virtual.bin"]
        state.beginDownload(total: 1)
        state.requestCancellation()
        XCTAssertTrue(state.isRunning)
        XCTAssertTrue(state.isCancelling)
        XCTAssertTrue(state.hasSelection)
        XCTAssertFalse(state.isResultPresented)
        // A late queued progress callback must not replace the stopping state.
        state.updateProgress(.init(completed: 1, total: 1, bytesTransferred: 4096, currentFile: "virtual.bin"))
        XCTAssertEqual(state.progress?.completed, 0)

        let summary = BatchOperationSummary(succeeded: [], failed: [
            "virtual.bin": "下载目标清理失败，请检查并删除本次部分文件"
        ])
        state.finishBatch(message: SFTPBatchOperationFormatter.downloadResultMessage(
            for: summary, wasCancelled: true
        ))
        XCTAssertFalse(state.isRunning)
        XCTAssertFalse(state.isCancelling)
        XCTAssertFalse(state.hasSelection)
        XCTAssertTrue(state.isResultPresented)
        XCTAssertTrue(state.resultMessage.contains("目标清理失败"))
        XCTAssertTrue(state.resultMessage.contains("失败 1 项"))
    }

    func testCancellationDoesNotHideCleanupErrorBehindOrdinaryCancelledEntries() {
        var failed = Dictionary(uniqueKeysWithValues: (0..<8).map { ("cancelled-\($0)", "传输已取消") })
        failed["owned-partial.bin"] = "下载目标清理失败，请检查并删除本次部分文件"
        let message = SFTPBatchOperationFormatter.downloadResultMessage(
            for: .init(succeeded: ["complete.bin"], failed: failed), wasCancelled: true
        )
        XCTAssertTrue(message.contains("成功 1 项，取消 8 项，失败 1 项"))
        XCTAssertTrue(message.contains("owned-partial.bin"))
        XCTAssertTrue(message.contains("目标清理失败"))
    }

    func testCleanupFailurePrecedesOtherErrorsWhenDetailsAreBounded() {
        var failed = Dictionary(uniqueKeysWithValues: (0..<5).map { ("a-\($0)", "源文件不存在或已移动") })
        failed["z-partial.bin"] = "下载目标清理失败，请检查并删除本次部分文件"
        let message = SFTPBatchOperationFormatter.downloadResultMessage(
            for: .init(succeeded: [], failed: failed), wasCancelled: true
        )
        XCTAssertTrue(message.contains("z-partial.bin"))
        XCTAssertTrue(message.contains("目标清理失败"))
        XCTAssertTrue(message.contains("另有 3 项失败"))
    }

    func testLateCancellationReportsActualCompletedFiles() {
        let message = SFTPBatchOperationFormatter.downloadResultMessage(
            for: .init(succeeded: ["complete.bin"], failed: [:]), wasCancelled: true
        )
        XCTAssertTrue(message.contains("取消请求到达时下载已完成"))
        XCTAssertTrue(message.contains("共 1 项"))
        XCTAssertFalse(message.contains("失败"))
    }

    func testPageAbandonmentAndNextBatchResetCancellationState() {
        var state = SFTPBrowserBatchState()
        state.selectedIDs = ["old.bin"]
        state.beginDownload(total: 1)
        state.requestCancellation()
        state.cancelBatch()
        state.updateProgress(.init(completed: 1, total: 1, bytesTransferred: 1, currentFile: "old.bin"))
        XCTAssertNil(state.progress)
        XCTAssertFalse(state.isResultPresented)
        state.selectedIDs = ["new.bin"]
        state.beginDownload(total: 1)
        XCTAssertTrue(state.isRunning)
        XCTAssertFalse(state.isCancelling)
        XCTAssertFalse(state.isResultPresented)
        XCTAssertEqual(state.progress?.completed, 0)
    }
}
