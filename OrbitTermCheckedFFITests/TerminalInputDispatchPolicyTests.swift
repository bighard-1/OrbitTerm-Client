import XCTest

final class TerminalInputDispatchPolicyTests: XCTestCase {
    func testPrintableInputCanCoalesce() {
        XCTAssertFalse(TerminalInputDispatchPolicy.sendsImmediately(Array("orbit".utf8)))
    }

    func testTerminalControlsRemainImmediate() {
        XCTAssertTrue(TerminalInputDispatchPolicy.sendsImmediately([3]))
        XCTAssertTrue(TerminalInputDispatchPolicy.sendsImmediately([9]))
        XCTAssertTrue(TerminalInputDispatchPolicy.sendsImmediately([13]))
        XCTAssertTrue(TerminalInputDispatchPolicy.sendsImmediately([27, 91, 65]))
    }

    func testLargePasteFlushesWithoutWaitingForCoalescingWindow() {
        let paste = Array(repeating: UInt8(ascii: "x"), count: TerminalInputDispatchPolicy.maximumCoalescedBytes)
        XCTAssertTrue(TerminalInputDispatchPolicy.sendsImmediately(paste))
    }
}
