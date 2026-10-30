import SwiftUI
#if os(macOS)
import AppKit
#endif

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
    let onBatchDownload: ([FileItem]) async -> BatchDownloadResult
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
    @State private var isBatchDeleteRunning = false
    @StateObject private var batchDownload = SFTPBatchDownloadController()

    private var isBatchOperationRunning: Bool { isBatchDeleteRunning || batchDownload.state.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            SFTPPathNavigator(
                path: $pathInput,
                isEnabled: canBrowse,
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
            .disabled(isBatchOperationRunning)

            if selectedItemIDs.count > 1 || isBatchOperationRunning {
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
                        Text(transferSummaryText)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(palette.textSecondary.color)
                    }
                }
            }
            .accessibilityIdentifier("workstation.sftp.transfers")
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
                runBatchDelete()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将逐项核对远端修订后删除；此操作无法撤销。")
        }
        .alert("批量下载结果", isPresented: Binding(
            get: { batchDownload.state.isResultPresented },
            set: { if !$0 { batchDownload.dismissResult() } }
        )) {
            Button("确定", role: .cancel) { batchDownload.dismissResult() }
#if os(macOS)
            if !batchDownload.state.completedDownloadURLs.isEmpty {
                Button("在 Finder 中显示") {
                    batchDownload.dismissResult()
                    let urls = batchDownload.takeCompletedDownloads()
                    if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                }
            }
#endif
        } message: {
            Text(batchDownload.state.resultMessage)
        }
        .onDisappear { abandonBatchDownload() }
        .onChange(of: ObjectIdentifier(sftpManager)) { _, _ in abandonBatchDownload() }
        .onChange(of: sftpManager.activeSessionID) { _, _ in abandonBatchDownload() }
        .onChange(of: sftpManager.currentPath) { _, _ in abandonBatchDownload() }
        .onChange(of: batchDownload.state.isRunning) { _, running in
            if !running { selectedItemIDs.removeAll() }
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
        sftpManager.isConnected && !sftpManager.isLoading && !isBatchOperationRunning
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

    private var transferSummaryText: String {
        let active = sftpManager.transfers.filter { !$0.isDone }.count
        let succeeded = sftpManager.transfers.filter { $0.isDone && $0.progress >= 1 }.count
        let incomplete = sftpManager.transfers.filter { $0.isDone && $0.progress < 1 }.count
        return "\(active) 进行中 · \(succeeded) 成功 · \(incomplete) 未完成"
    }

    private var selectionToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(batchDownload.state.isRunning
                    ? "本次下载 \(batchDownload.state.progress?.total ?? 0) 项"
                    : "已选 \(selectedItemIDs.count) 项")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                Button(batchDownload.state.isCancelling ? "正在停止…"
                    : batchDownload.state.isRunning ? "取消传输" : "取消选择") {
                    if batchDownload.state.isRunning {
                        batchDownload.requestCancellation()
                    } else {
                        selectedItemIDs.removeAll()
                    }
                }
                .buttonStyle(.borderless)
                .disabled(batchDownload.state.isCancelling || isBatchDeleteRunning)
                .accessibilityIdentifier("workstation.sftp.batch.cancel")
            }
            if batchDownload.state.isRunning {
                Label(batchDownload.state.isCancelling
                    ? "正在停止传输并等待目标清理，请稍候。"
                    : "正在下载，可取消本次传输。", systemImage: "hourglass")
                    .font(.caption)
            } else if isBatchDeleteRunning {
                Text("正在删除所选项目…").font(.caption)
            }
            HStack(spacing: 8) {
                Button("下载") { startBatchDownload() }
                    .disabled(isBatchOperationRunning || !canBrowse || selectedItems.allSatisfy(\.isDirectory))
                    .accessibilityIdentifier("workstation.sftp.batch.download")
                Button("删除", role: .destructive) {
                    isBatchDeleteConfirmationPresented = true
                }
                .disabled(isBatchOperationRunning || !canBrowse)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(palette.surfaceGlassStrong.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(palette.borderGlass.color, lineWidth: 1))
    }

    private func startBatchDownload() {
        guard !isBatchOperationRunning, canBrowse else { return }
        let operation = onBatchDownload
        let targets = selectedItems
        batchDownload.start(items: targets) { files in
            await operation(files)
        }
    }

    private func abandonBatchDownload() {
        batchDownload.abandon()
        selectedItemIDs.removeAll()
    }

    private func runBatchDelete() {
        guard !isBatchOperationRunning else { return }
        let targets = selectedItems
        let operation = onBatchDelete
        isBatchDeleteRunning = true
        Task {
            await operation(targets)
            selectedItemIDs.removeAll()
            isBatchDeleteRunning = false
        }
    }
}
