import SwiftUI

/// Read-only syntax presentation for commands before they are inserted or run.
/// Terminal rendering remains exclusively owned by TerminalTheme and SwiftTerm.
struct ShellSyntaxHighlightedText: View {
    let source: String
    let lineLimit: Int?

    @Environment(\.appThemePalette) private var palette

    init(_ source: String, lineLimit: Int? = nil) {
        self.source = source
        self.lineLimit = lineLimit
    }

    var body: some View {
        renderedText
            .font(.system(.caption, design: .monospaced))
            .lineLimit(lineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("命令预览")
            .accessibilityValue(source)
    }

    private var renderedText: Text {
        ShellSyntaxHighlighter.tokenize(source).reduce(Text("")) { partial, token in
            partial + Text(token.text).foregroundColor(color(for: token.role))
        }
    }

    private func color(for role: ShellSyntaxRole) -> Color {
        switch role {
        case .command:
            palette.accentPrimary.color
        case .option:
            palette.accentSecondary.color
        case .string:
            Color.orange
        case .variable:
            Color.purple
        case .comment:
            palette.textDisabled.color
        case .operator:
            palette.textSecondary.color
        case .plain:
            palette.textPrimary.color
        }
    }
}
