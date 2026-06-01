import Foundation

enum SnippetVariableResolver {
    static func extractVariables(from command: String) -> [String] {
        let pattern = #"\{\{([a-zA-Z0-9_]+)\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let ns = command as NSString
        let matches = regex.matches(in: command, range: NSRange(location: 0, length: ns.length))
        let keys = matches.compactMap { match -> String? in
            guard match.numberOfRanges > 1 else { return nil }
            return ns.substring(with: match.range(at: 1))
        }
        return Array(Set(keys)).sorted()
    }

    static func resolve(_ command: String, values: [String: String]) -> String {
        values.reduce(command) { partial, item in
            partial.replacingOccurrences(of: "{{\(item.key)}}", with: item.value)
        }
    }
}

extension UUID {
    static let snippetDraftID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
