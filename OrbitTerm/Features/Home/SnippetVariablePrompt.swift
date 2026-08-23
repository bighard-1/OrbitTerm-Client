import Foundation

enum SnippetInvocation {
    case insert
    case execute
    case batch

    var executesImmediately: Bool { self == .execute }
}

struct SnippetVariablePrompt: Identifiable {
    let id = UUID()
    let snippet: Snippet
    let invocation: SnippetInvocation
    var variableValues: [String: String]
}
