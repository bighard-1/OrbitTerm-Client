import SwiftUI

struct WorkstationTerminalSearchOverlay: View {
    @Binding var isPresented: Bool
    @Binding var searchText: String
    @Binding var searchCommand: TerminalSearchCommand?
    @Binding var searchStatusText: String
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索终端历史", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFocused)
                    .onSubmit { triggerSearch(.next) }

                Button {
                    triggerSearch(.previous)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.bordered)

                Button {
                    triggerSearch(.next)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.bordered)

                Button {
                    searchText = ""
                    triggerSearch(.clear)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.bordered)

                Button("关闭") {
                    isPresented = false
                    searchStatusText = ""
                }
                .buttonStyle(.bordered)
            }

            if !searchStatusText.isEmpty {
                Text(searchStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: focusSearchField)
        .onChange(of: isPresented) { _, newValue in
            guard newValue else { return }
            focusSearchField()
        }
    }

    private func triggerSearch(_ action: TerminalSearchAction) {
        searchCommand = TerminalSearchCommand(action: action)
    }

    private func focusSearchField() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isSearchFocused = true
        }
    }
}

struct WorkstationTerminalSearchShortcutModifier: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
#if os(macOS)
            Button("") {
                isPresented = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0.001)
            .frame(width: 1, height: 1)
#endif
        }
    }
}
