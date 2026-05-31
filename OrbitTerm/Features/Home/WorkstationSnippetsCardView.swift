import SwiftUI

struct WorkstationSnippetsCardView: View {
    let active: WorkspaceSession
    @ObservedObject var snippetStore: SnippetStore
    let onHide: () -> Void
    let onInsertCommand: (String, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Snippets")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(action: onHide) {
                    Image(systemName: "eye.slash")
                }
                .buttonStyle(.borderless)
            }

            SnippetsPanelView(
                snippetStore: snippetStore,
                session: active,
                onInsertCommand: onInsertCommand
            )
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
