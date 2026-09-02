import SwiftUI

struct TabBarView: View {
    @Environment(\.appThemePalette) private var palette
    let tabs: [WorkspaceSession]
    let activeTabID: UUID?
    let onSelect: (WorkspaceSession) -> Void
    let onClose: (WorkspaceSession) -> Void
    let onNew: () -> Void
    let onDetach: (WorkspaceSession) -> Void
    let onDisconnect: (WorkspaceSession) -> Void
    let onReconnect: (WorkspaceSession) -> Void

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
                .foregroundStyle(palette.accentPrimary.color)
                .background(palette.accentPrimary.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(palette.accentPrimary.color.opacity(0.45))
                }
                .accessibilityLabel("新建会话")
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
        }
        .background(palette.surfaceReadable.color)
    }

    private func tabItem(_ tab: WorkspaceSession) -> some View {
        TabBarItemView(
            tab: tab,
            isActive: tab.id == activeTabID,
            onSelect: { onSelect(tab) },
            onClose: { onClose(tab) },
            onDetach: { onDetach(tab) },
            onDisconnect: { onDisconnect(tab) },
            onReconnect: { onReconnect(tab) }
        )
    }
}

private struct TabBarItemView: View {
    @ObservedObject var tab: WorkspaceSession
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onDetach: () -> Void
    let onDisconnect: () -> Void
    let onReconnect: () -> Void
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            ConnectionStatusBadge(presentation: status(for: tab)).font(.caption2)

            Text(tab.server.name)
                .lineLimit(1)
                .font(.system(size: 12, weight: .medium))

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.textSecondary.color)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭 (tab.server.name) 会话")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? palette.accentPrimary.color.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isActive ? palette.focusRing.color : palette.borderGlass.color, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tab.server.name)，\(status(for: tab).label)")
        .accessibilityHint("双击切换到此会话")
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            if tab.isConnected {
                Button("断开连接", role: .destructive, action: onDisconnect)
            }
            Button(tab.isConnected ? "重新连接" : "连接", action: onReconnect)
            Divider()
            Button("在新窗口打开", action: onDetach)
            Button("关闭标签", action: onClose)
        }
    }

    private func status(for tab: WorkspaceSession) -> ConnectionPresentation {
        tab.connectionPresentation
    }
}
