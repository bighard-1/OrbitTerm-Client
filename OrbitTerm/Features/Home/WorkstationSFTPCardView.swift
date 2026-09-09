import SwiftUI

struct WorkstationSFTPCardView: View {
    @ObservedObject var sftpManager: SFTPManager
    let onRefresh: () -> Void
    let onUpload: () -> Void
    let onCreateDirectory: () -> Void
    let onCreateFile: () -> Void
    let onUp: () -> Void
    let onNavigateToPath: (String) async -> Bool
    let pathFocusRequest: Int
    let onEnterDirectory: (FileItem) -> Void
    let onOpenFile: (FileItem) -> Void
    let onDownload: (FileItem) -> Void
    let onRename: (FileItem) -> Void
    let onChmod: (FileItem) -> Void
    let onSetMode: (FileItem, String) -> Void
    let onDelete: (FileItem) -> Void
    @Environment(\.appThemePalette) private var palette
    @State private var hoveredItemID: FileItem.ID?
    @State private var pathInput = ""
    @State private var isTransferQueueExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            SFTPPathNavigator(
                path: $pathInput,
                isEnabled: sftpManager.isConnected && !sftpManager.isLoading,
                focusRequest: pathFocusRequest,
                onNavigate: {
                    let requestedPath = pathInput
                    Task {
                        if await onNavigateToPath(requestedPath) {
                            pathInput = sftpManager.currentPath
                        }
                    }
                }
            )

            Text(sftpManager.statusText)
                .font(.caption)
                .foregroundStyle(palette.textSecondary.color)

            HStack(spacing: 10) {
                Text("总计 \(sftpManager.items.count)")
                Text("目录 \(sftpManager.items.filter { $0.isDirectory }.count)")
                Text("文件 \(sftpManager.items.filter { !$0.isDirectory }.count)")
            }
            .font(.caption2)
            .foregroundStyle(palette.textSecondary.color)

            // The command bar and summary belong to the card chrome.  Only the
            // directory listing scrolls so file navigation never hides actions.
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if sftpManager.items.isEmpty {
                            Text("连接后自动展示远程文件")
                                .font(.caption)
                                .foregroundStyle(palette.textSecondary.color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(sftpManager.items) { item in
                                fileRow(item)
                                    .id(item.id)
                            }
                        }
                    }
                }
                .onChange(of: sftpManager.highlightedItemID) { _, itemID in
                    guard let itemID else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(itemID, anchor: .center)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .contextMenu {
                directoryActions
            }

            DisclosureGroup(isExpanded: $isTransferQueueExpanded) {
                SFTPTransferBoard(manager: sftpManager)
                    .padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    Text("传输任务")
                        .font(.caption.weight(.semibold))
                    if !sftpManager.transfers.isEmpty {
                        Text("\(sftpManager.transfers.filter { !$0.isDone }.count) 进行中 · \(sftpManager.transfers.filter { $0.isDone }.count) 完成")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(palette.textSecondary.color)
                    }
                }
            }
            .accessibilityLabel("SFTP 传输任务队列")
        }
        .padding(10)
        .foregroundStyle(palette.textPrimary.color)
        .background(palette.surfaceGlassStrong.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.borderGlass.color, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onUp) {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(!canBrowse || sftpManager.currentPath == "/")
            .help("返回上级目录")
            .accessibilityLabel("返回上级目录")

            Spacer(minLength: 0)

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(!canBrowse)
            .help("刷新当前目录")
            .accessibilityLabel("刷新当前目录")

            Menu {
                directoryActions
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .disabled(!canBrowse)
            .help("当前目录操作")
            .accessibilityLabel("当前目录操作")
        }
    }

    @ViewBuilder
    private var directoryActions: some View {
        Button("上传文件…", action: onUpload)
            .disabled(!canBrowse)
        Divider()
        Button("新建目录…", action: onCreateDirectory)
            .disabled(!canBrowse)
        Button("新建文件…", action: onCreateFile)
            .disabled(!canBrowse)
        Divider()
        Button("刷新当前目录", action: onRefresh)
            .disabled(!canBrowse)
        Button("返回上级目录", action: onUp)
            .disabled(!canBrowse || sftpManager.currentPath == "/")
    }

    private var canBrowse: Bool {
        sftpManager.isConnected && !sftpManager.isLoading
    }

    private func fileRow(_ item: FileItem) -> some View {
        HStack {
            Image(systemName: item.iconName)
                .foregroundStyle(item.isDirectory ? palette.accentPrimary.color : palette.textSecondary.color)
            Text(item.name)
                .lineLimit(1)
            Spacer()
            if !item.isDirectory {
                Text(item.formattedSize)
                    .font(.caption2)
                    .foregroundStyle(palette.textSecondary.color)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if item.isDirectory {
                onEnterDirectory(item)
            } else {
                onOpenFile(item)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            hoveredItemID == item.id || sftpManager.highlightedItemID == item.id
                ? palette.surfaceInput.color
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    sftpManager.highlightedItemID == item.id ? palette.focusRing.color.opacity(0.8) : Color.clear,
                    lineWidth: 1
                )
        }
#if os(macOS)
        .onHover { hoveredItemID = $0 ? item.id : nil }
#endif
        .contextMenu {
            if item.isDirectory {
                Button("进入目录") { onEnterDirectory(item) }
            } else {
                Button("打开并编辑") { onOpenFile(item) }
                Button("下载到桌面") { onDownload(item) }
            }
            Button("重命名") { onRename(item) }
            Button("权限...") { onChmod(item) }
            Button("设为 644") { onSetMode(item, "644") }
            Button("设为 755") { onSetMode(item, "755") }
            Button("设为 600") { onSetMode(item, "600") }
            Button("删除", role: .destructive) { onDelete(item) }
        }
    }
}
