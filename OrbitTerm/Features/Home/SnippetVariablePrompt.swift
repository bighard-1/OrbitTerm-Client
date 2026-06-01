import Foundation

struct SnippetVariablePrompt: Identifiable {
    let id = UUID()
    let snippet: Snippet
    let executeImmediately: Bool
    var variableValues: [String: String]
}
