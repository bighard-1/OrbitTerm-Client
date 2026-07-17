import SwiftUI

struct WorkstationSnippetsCardView: View {
    let active: WorkspaceSession
    @ObservedObject var snippetStore: SnippetStore
    let onInsertCommand: (String, Bool) -> Void
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Snippets")
                    .font(.subheadline.weight(.semibold))
                Text("按分类管理")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
                Spacer()
            }

            SnippetsPanelView(
                snippetStore: snippetStore,
                session: active,
                onInsertCommand: onInsertCommand
            )
        }
        .padding(10)
        .background(palette.surfaceGlassStrong.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.borderGlass.color)
        }
    }
}
