import XCTest

final class OperationResourceBudgetTests: XCTestCase {
    func testTerminalBudgetsKeepOnlyNewestBytes() {
        let source = Data((0..<100).map(UInt8.init))
        let result = OperationResourceBudget.tail(source, maximumBytes: 16)

        XCTAssertEqual(result.count, 16)
        XCTAssertEqual(result, Data((84..<100).map(UInt8.init)))
        XCTAssertLessThanOrEqual(
            OperationResourceBudget.terminalPendingBytesPerChannel,
            OperationResourceBudget.terminalReplayBytesPerChannel
        )
    }

    func testSFTPWorkerBudgetIsBounded() {
        XCTAssertEqual(
            OperationConcurrencyPolicy.workerCount(
                requested: 99,
                itemCount: 99,
                maximum: OperationResourceBudget.sftpMaximumConcurrentTransfers
            ),
            OperationResourceBudget.sftpMaximumConcurrentTransfers
        )
    }

    func testMonitorAndChartBudgetsStayBounded() {
        XCTAssertGreaterThan(OperationResourceBudget.monitorPointsPerPanel, 0)
        XCTAssertLessThanOrEqual(
            OperationResourceBudget.monitorChartPoints,
            OperationResourceBudget.monitorPointsPerPanel
        )
        XCTAssertEqual(
            OperationResourceBudget.prefix(Array(0..<500), maximumCount: 3),
            [0, 1, 2]
        )
        XCTAssertEqual(
            OperationResourceBudget.prefix(
                Array(0..<100),
                maximumCount: OperationResourceBudget.sftpRetainedCompletedTransfers
            ).count,
            OperationResourceBudget.sftpRetainedCompletedTransfers
        )
    }

    func testSyncBudgetIsSingleDeliveryAndPageIsBounded() {
        XCTAssertEqual(OperationResourceBudget.syncMaximumConcurrentDeliveries, 1)
        XCTAssertGreaterThan(OperationResourceBudget.syncIncrementalPageSize, 0)
        XCTAssertLessThanOrEqual(OperationResourceBudget.syncIncrementalPageSize, 100)
        XCTAssertTrue(OperationResourceBudget.permitsSyncDelivery(activeDeliveries: 0))
        XCTAssertFalse(OperationResourceBudget.permitsSyncDelivery(activeDeliveries: 1))
    }
}
