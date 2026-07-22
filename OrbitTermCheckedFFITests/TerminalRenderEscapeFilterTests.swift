import XCTest

final class TerminalRenderEscapeFilterTests: XCTestCase {
    func testRemovesOnlyWindowManipulationCommand() {
        var filter = TerminalRenderEscapeFilter()
        let input = Array("before\u{001B}[8;42;120tafter".utf8)

        XCTAssertEqual(String(decoding: filter.filter(input), as: UTF8.self), "beforeafter")
    }

    func testPreservesOrdinaryANSISequences() {
        var filter = TerminalRenderEscapeFilter()
        let input = Array("\u{001B}[31mred\u{001B}[0m".utf8)

        XCTAssertEqual(filter.filter(input), input)
    }

    func testRecognizesWindowCommandSplitAcrossTerminalChunks() {
        var filter = TerminalRenderEscapeFilter()

        XCTAssertEqual(filter.filter([0x1B, 0x5B, 0x38, 0x3B]), [])
        XCTAssertEqual(filter.filter([0x34, 0x32, 0x3B, 0x31, 0x32, 0x30, 0x74, 0x58]), [0x58])
    }
}
