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
    let onBatchDownload: ([FileItem]) async -> Void
    let onRename: (FileItem) -> Void
    let onChmod: (FileItem) -> Void
    let onSetMode: (FileItem, String) -> Void
    let onDelete: (FileItem) -> Void
    let onBatchDelete: ([FileItem]) async -> Void
    @Environment(\.appThemePalette) private var palette
    @State private var hoveredItemID: FileItem.ID?
    @State private var pathInput = ""
    @State private var isTransferQueueExpanded = false
    @State private var selectedItemIDs: Set<String> = []
    @State private var isBatchDeleteConfirmationPresented = false
    @State private var isBatchOperationRunning = false

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
                List(selection: $selectedItemIDs) {
                    if sftpManager.items.isEmpty {
                        Text("连接后自动展示远程文件")
                            .font(.caption)
                            .foregroundStyle(palette.textSecondary.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(sftpManager.items) { item in
                            fileRow(item)
                                .tag(item.id)
                                .id(item.id)
                                .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                                .listRowBackground(Color.clear)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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

            if selectedItemIDs.count > 1 {
                selectionToolbar
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
        .confirmationDialog(
            "删除所选 \(selectedItems.count) 项？",
            isPresented: $isBatchDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                runBatchOperation { await onBatchDelete(selectedItems) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将逐项核对远端修订后删除；此操作无法撤销。")
        }
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
            selectedItemIDs.contains(item.id) || hoveredItemID == item.id || sftpManager.highlightedItemID == item.id
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
            Divider()
            Button(selectedItemIDs.contains(item.id) ? "从批量选择中移除" : "加入批量选择") {
                if selectedItemIDs.contains(item.id) {
                    selectedItemIDs.remove(item.id)
                } else {
                    selectedItemIDs.insert(item.id)
                }
            }
        }
    }

    private var selectedItems: [FileItem] {
        sftpManager.items.filter { selectedItemIDs.contains($0.id) }
    }

    private var selectionToolbar: some View {
        HStack(spacing: 8) {
            Text("已选 \(selectedItemIDs.count) 项")
                .font(.caption.weight(.semibold))
            Spacer(minLength: 4)
            Button("取消") { selectedItemIDs.removeAll() }
                .buttonStyle(.borderless)
                .disabled(isBatchOperationRunning)
            Button("下载") {
                let files = selectedItems.filter { !$0.isDirectory }
                runBatchOperation { await onBatchDownload(files) }
            }
            .disabled(isBatchOperationRunning || selectedItems.allSatisfy(\.isDirectory))
            Button("删除", role: .destructive) {
                isBatchDeleteConfirmationPresented = true
            }
            .disabled(isBatchOperationRunning)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(palette.surfaceGlassStrong.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(palette.borderGlass.color, lineWidth: 1))
    }

    private func runBatchOperation(_ operation: @escaping () async -> Void) {
        guard !isBatchOperationRunning else { return }
        isBatchOperationRunning = true
        Task {
            await operation()
            selectedItemIDs.removeAll()
            isBatchOperationRunning = false
        }
    }
}
