import SwiftUI

struct TabBarView: View {
    let tabs: [WorkspaceSession]
    let activeTabID: UUID?
    let onSelect: (WorkspaceSession) -> Void
    let onClose: (WorkspaceSession) -> Void
    let onNew: () -> Void
    let onDetach: (WorkspaceSession) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabs) { tab in
                    tabItem(tab)
                }

                Button {
                    onNew()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
        }
        .background(.ultraThinMaterial)
    }

    private func tabItem(_ tab: WorkspaceSession) -> some View {
        let isActive = tab.id == activeTabID
        return HStack(spacing: 8) {
            Circle()
                .fill(tab.isConnected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            Text(tab.server.name)
                .lineLimit(1)
                .font(.system(size: 12, weight: .medium))

            Button {
                onClose(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isActive ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(tab)
        }
        .contextMenu {
            Button("在新窗口打开") {
                onDetach(tab)
            }
            Button("关闭标签") {
                onClose(tab)
            }
        }
    }
}
