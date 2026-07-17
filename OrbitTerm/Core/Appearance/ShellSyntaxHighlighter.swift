import Foundation

/// A deliberately small, presentation-only shell lexer. It never executes or
/// validates a command; its output is used solely by read-only command previews.
enum ShellSyntaxRole: Hashable, Sendable {
    case command
    case option
    case string
    case variable
    case comment
    case `operator`
    case plain
}

struct ShellSyntaxToken: Hashable, Sendable {
    let text: String
    let role: ShellSyntaxRole
}

enum ShellSyntaxHighlighter {
    static func tokenize(_ source: String) -> [ShellSyntaxToken] {
        let characters = Array(source)
        var tokens: [ShellSyntaxToken] = []
        var index = 0
        var expectsCommand = true

        func append(_ text: String, role: ShellSyntaxRole) {
            guard !text.isEmpty else { return }
            if let last = tokens.last, last.role == role {
                tokens[tokens.count - 1] = ShellSyntaxToken(text: last.text + text, role: role)
            } else {
                tokens.append(ShellSyntaxToken(text: text, role: role))
            }
        }

        while index < characters.count {
            let character = characters[index]

            if character.isWhitespace {
                var text = ""
                while index < characters.count, characters[index].isWhitespace {
                    text.append(characters[index])
                    index += 1
                }
                append(text, role: .plain)
                continue
            }

            if character == "#", startsComment(after: tokens) {
                append(String(characters[index...]), role: .comment)
                break
            }

            if character == "\"" || character == "'" {
                let quote = character
                var text = String(quote)
                index += 1
                while index < characters.count {
                    let next = characters[index]
                    text.append(next)
                    index += 1
                    if next == quote { break }
                }
                append(text, role: .string)
                expectsCommand = false
                continue
            }

            if character == "$" {
                let (text, nextIndex) = variableToken(from: characters, startingAt: index)
                append(text, role: .variable)
                index = nextIndex
                expectsCommand = false
                continue
            }

            if isOperator(character) {
                var text = String(character)
                index += 1
                if index < characters.count,
                   (character == "&" || character == "|" || character == ">" || character == "<"),
                   characters[index] == character {
                    text.append(characters[index])
                    index += 1
                }
                append(text, role: .operator)
                expectsCommand = character == "|" || character == ";" || character == "&"
                continue
            }

            var word = ""
            while index < characters.count,
                  !characters[index].isWhitespace,
                  !isOperator(characters[index]),
                  characters[index] != "\"",
                  characters[index] != "'",
                  characters[index] != "$" {
                word.append(characters[index])
                index += 1
            }
            let role: ShellSyntaxRole
            if expectsCommand {
                role = .command
            } else if word.hasPrefix("-") {
                role = .option
            } else {
                role = .plain
            }
            append(word, role: role)
            expectsCommand = false
        }

        return tokens
    }

    private static func startsComment(after tokens: [ShellSyntaxToken]) -> Bool {
        guard let last = tokens.last else { return true }
        return last.role == .plain && last.text.last?.isWhitespace == true || last.role == .operator
    }

    private static func isOperator(_ character: Character) -> Bool {
        "|&;()<>".contains(character)
    }

    private static func variableToken(from characters: [Character], startingAt index: Int) -> (String, Int) {
        var cursor = index + 1
        guard cursor < characters.count else { return ("$", cursor) }

        if characters[cursor] == "{" {
            cursor += 1
            while cursor < characters.count, characters[cursor] != "}" { cursor += 1 }
            if cursor < characters.count { cursor += 1 }
            return (String(characters[index..<cursor]), cursor)
        }

        while cursor < characters.count,
              characters[cursor].isLetter || characters[cursor].isNumber || characters[cursor] == "_" {
            cursor += 1
        }
        return (String(characters[index..<cursor]), cursor)
    }
}
