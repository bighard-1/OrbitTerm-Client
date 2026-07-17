import XCTest

final class ShellSyntaxHighlighterTests: XCTestCase {
    func testRecognizesCommandOptionsVariablesAndComment() {
        let tokens = ShellSyntaxHighlighter.tokenize("grep -n \"$HOME\" file # note")

        XCTAssertTrue(tokens.contains(ShellSyntaxToken(text: "grep", role: .command)))
        XCTAssertTrue(tokens.contains(ShellSyntaxToken(text: "-n", role: .option)))
        XCTAssertTrue(tokens.contains(where: { $0.role == .string && $0.text.contains("$HOME") }))
        XCTAssertTrue(tokens.contains(ShellSyntaxToken(text: "# note", role: .comment)))
    }

    func testRecognizesOperatorsAsNewCommandBoundaries() {
        let tokens = ShellSyntaxHighlighter.tokenize("cat file | grep name && echo done")
        let commands = tokens.filter { $0.role == .command }.map(\.text)

        XCTAssertEqual(commands, ["cat", "grep", "echo"])
        XCTAssertTrue(tokens.contains(ShellSyntaxToken(text: "|", role: .operator)))
        XCTAssertTrue(tokens.contains(ShellSyntaxToken(text: "&&", role: .operator)))
    }

    func testHashInsideWordIsNotTreatedAsComment() {
        let tokens = ShellSyntaxHighlighter.tokenize("echo value#fragment")

        XCTAssertFalse(tokens.contains(where: { $0.role == .comment }))
        XCTAssertEqual(tokens.map(\.text).joined(), "echo value#fragment")
    }

    func testTokenizerPreservesSourceExactly() {
        let source = "printf '${name}' > output.txt"
        XCTAssertEqual(ShellSyntaxHighlighter.tokenize(source).map(\.text).joined(), source)
    }
}
