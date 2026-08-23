import Foundation
import XCTest

/// Deterministic, in-process stress gate for the production bounded-storage
/// primitives. It intentionally uses synthetic data only: no SSH session,
/// account, path, command, or remote output is involved.
final class OperationResourceBudgetStressTests: XCTestCase {
    private let componentDeadline: TimeInterval = 5

    func testTerminalHighOutputRetainsOnlyConfiguredPendingAndReplayBudgets() async {
        let startedAt = Date()
        let buffer = TerminalChunkBuffer()
        let channelID: UInt64 = 42
        let chunkSize = 256 * 1024

        for index in 0..<64 {
            await buffer.ingest(
                channelID: channelID,
                bytes: Data(repeating: UInt8(index), count: chunkSize),
                queueForDelivery: true
            )
        }

        let replay = await buffer.replay(channelID: channelID)
        let pending = await buffer.drainAll()[channelID] ?? Data()

        XCTAssertEqual(replay.count, OperationResourceBudget.terminalReplayBytesPerChannel)
        XCTAssertEqual(pending.count, OperationResourceBudget.terminalPendingBytesPerChannel)
        XCTAssertEqual(replay.first, 32, "replay must evict the oldest 8 MiB")
        XCTAssertEqual(pending.first, 60, "pending delivery must evict the oldest 1 MiB")
        assertCompletedWithinDeadline(since: startedAt)
    }

    func testMonitorHistoryStaysChronologicalAndBoundedUnderLongSamplingRun() {
        let startedAt = Date()
        let capacity = OperationResourceBudget.monitorPointsPerPanel
        var history = BoundedCircularBuffer<Int>(capacity: capacity)

        for value in 0..<(capacity * 100) {
            history.append(value)
        }

        let retained = history.elementsInOrder
        XCTAssertEqual(retained.count, capacity)
        XCTAssertEqual(retained.first, capacity * 99)
        XCTAssertEqual(retained.last, capacity * 100 - 1)
        assertCompletedWithinDeadline(since: startedAt)
    }

    func testDockerRenderedLogNeverExceedsPresentationBudgetUnderLargePayload() {
        let startedAt = Date()
        let source = String(repeating: "x", count: OperationResourceBudget.dockerRenderedLogBytes * 2)
        let rendered = DockerLogPresentationBuffer.renderedText(source)

        XCTAssertLessThanOrEqual(rendered.utf8.count, OperationResourceBudget.dockerRenderedLogBytes)
        XCTAssertTrue(rendered.hasPrefix("(为控制内存，仅显示最新日志)"))
        XCTAssertTrue(rendered.hasSuffix("x"))
        assertCompletedWithinDeadline(since: startedAt)
    }

    func testSFTPAdmissionGateNeverExceedsTransferBudgetDuringBurst() {
        let startedAt = Date()
        var gate = OperationConcurrencyGate(
            maximumConcurrentOperations: OperationResourceBudget.sftpMaximumConcurrentTransfers
        )

        XCTAssertEqual(gate.acquire(requestedSlots: 99), OperationResourceBudget.sftpMaximumConcurrentTransfers)
        XCTAssertNil(gate.acquire())
        XCTAssertEqual(gate.activeOperationCount, OperationResourceBudget.sftpMaximumConcurrentTransfers)
        gate.release(slots: 2)
        XCTAssertEqual(gate.acquire(requestedSlots: 2), 2)
        XCTAssertEqual(gate.activeOperationCount, OperationResourceBudget.sftpMaximumConcurrentTransfers)

        for _ in 0..<10_000 {
            gate.release()
            XCTAssertNotNil(gate.acquire())
            XCTAssertLessThanOrEqual(
                gate.activeOperationCount,
                OperationResourceBudget.sftpMaximumConcurrentTransfers
            )
        }
        gate.reset()
        XCTAssertEqual(gate.activeOperationCount, 0)
        assertCompletedWithinDeadline(since: startedAt)
    }

    func testSyncDeliveryAdmissionRemainsSingleFlightDuringBurst() {
        let startedAt = Date()

        for _ in 0..<10_000 {
            XCTAssertTrue(OperationResourceBudget.permitsSyncDelivery(activeDeliveries: 0))
            XCTAssertFalse(OperationResourceBudget.permitsSyncDelivery(activeDeliveries: 1))
            XCTAssertFalse(OperationResourceBudget.permitsSyncDelivery(activeDeliveries: 99))
        }
        assertCompletedWithinDeadline(since: startedAt)
    }

    private func assertCompletedWithinDeadline(
        since startedAt: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            componentDeadline,
            "bounded resource primitive exceeded its deterministic stress deadline",
            file: file,
            line: line
        )
    }
}
