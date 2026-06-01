import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct SFTPBrowserView: View {
    @StateObject private var manager = SFTPManager()
    @ObservedObject private var sessionManager = SessionManager.shared
    private let vault = CredentialVault.shared

    @State private var connectionDraft = SFTPBrowserConnectionDraft()
    @State private var isDropTargeted: Bool = false
    @State private var editState = SFTPBrowserEditState()
    @State private var batchState = SFTPBrowserBatchState()

#if os(iOS)
    @State private var shareURLs: [URL] = []
    @State private var showingShareSheet = false
#else
    @State private var revealInFinderURL: URL?
#endif

    private var effectiveManager: SFTPManager {
        sessionManager.activeSession?.sftpManager ?? manager
    }

    var body: some View {
        VStack(spacing: 0) {
            if !effectiveManager.isConnected {
                connectPanel
            } else {
                browserPanel
            }
        }
        .navigationTitle("SFTP")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task {
            effectiveManager.activateMockIfNeeded(
                host: connectionDraft.host,
                username: connectionDraft.username,
                password: connectionDraft.password
            )
            await autoBindActiveSessionIfNeeded()
        }
        .alert("重命名", isPresented: Binding(
            get: { editState.isRenaming },
            set: { editState.isRenaming = $0 }
        )) {
            TextField("新名称", text: $editState.renameName)
            Button("取消", role: .cancel) { editState.cancelRename() }
            Button("确认") {
                if let renameItem = editState.renameItem {
                    let newName = editState.renameName
                    Task { await effectiveManager.rename(item: renameItem, to: newName) }
                }
                editState.cancelRename()
            }
        } message: {
            Text("输入新的文件名")
        }
        .alert("修改权限", isPresented: Binding(
            get: { editState.isChangingPermissions },
            set: { editState.isChangingPermissions = $0 }
        )) {
            TextField("例如 644 / 755 / 600", text: $editState.chmodMode)
            Button("取消", role: .cancel) { editState.cancelChmod() }
            Button("确认") {
                guard let target = editState.chmodItem else { return }
                let mode = editState.chmodMode
                Task { await effectiveManager.chmod(item: target, modeOctal: mode) }
                editState.cancelChmod()
            }
        } message: {
            Text("请输入 3-4 位八进制权限")
        }
        .alert("新建目录", isPresented: $editState.isCreatingFolder) {
            TextField("目录名称", text: $editState.createFolderName)
            Button("取消", role: .cancel) { editState.finishCreateFolder() }
            Button("创建") {
                let folderName = editState.createFolderName
                Task { await effectiveManager.createDirectory(named: folderName) }
                editState.finishCreateFolder()
            }
        }
        .alert("新建文件", isPresented: $editState.isCreatingFile) {
            TextField("文件名称", text: $editState.createFileName)
            Button("取消", role: .cancel) { editState.finishCreateFile() }
            Button("创建") {
                let fileName = editState.createFileName
                Task { await effectiveManager.createFile(named: fileName) }
                editState.finishCreateFile()
            }
        }
        .alert("确认批量删除", isPresented: $batchState.isDeleteConfirmPresented) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await performBatchDelete() }
            }
        } message: {
            Text("即将删除 \(selectedItems.count) 项，删除后不可恢复。")
        }
        .alert("批量操作结果", isPresented: $batchState.isResultPresented) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(batchState.resultMessage)
        }
#if os(iOS)
        .sheet(isPresented: $showingShareSheet) {
            SFTPActivityShareSheet(activityItems: shareURLs)
        }
#endif
    }

    private var connectPanel: some View {
        Form {
            Section("连接信息") {
                TextField("主机或 IP", text: $connectionDraft.host)
                    .applyInputPolish()
                TextField("用户名", text: $connectionDraft.username)
                    .applyInputPolish()
                SecureField("密码", text: $connectionDraft.password)
            }

            Section("模式") {
                Toggle("优先使用模拟数据", isOn: $connectionDraft.preferMockMode)
                Text("若未配置 SSH，系统会自动进入 Mock 文件列表。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("操作") {
                Button(connectionDraft.preferMockMode ? "进入模拟浏览" : "连接 SFTP") {
                    Task {
                        await effectiveManager.connect(
                            host: connectionDraft.host,
                            username: connectionDraft.username,
                            password: connectionDraft.password,
                            preferMock: connectionDraft.preferMockMode
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(effectiveManager.isLoading)
            }

            if !effectiveManager.statusText.isEmpty {
                Section("状态") {
                    Text(effectiveManager.statusText)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var browserPanel: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                breadcrumbBar
                summaryBar

                if effectiveManager.isLoading {
                    ProgressView("加载中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if effectiveManager.items.isEmpty {
                    emptyFolderView
                } else {
                    fileList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            VStack(spacing: 8) {
#if os(macOS)
                if let revealURL = revealInFinderURL {
                    SFTPRevealInFinderToast(revealURL: revealURL) {
                            NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                            revealInFinderURL = nil
                    }
                }
#endif

                if batchState.hasSelection {
                    SFTPBatchToolbar(
                        selectedCount: batchState.selectedIDs.count,
                        progress: batchState.progress,
                        isRunning: batchState.isRunning,
                        onCancel: { batchState.clearSelection() },
                        onDownload: { Task { await performBatchDownload() } },
                        onDelete: { batchState.requestDeleteConfirmation() }
                    )
                        .padding(.horizontal, 12)
                }

                SFTPTransferBoard(transfers: effectiveManager.transfers)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("刷新") {
                    Task {
                        try? await effectiveManager.refresh()
                        batchState.clearSelection()
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("断开") {
                    Task {
                        await effectiveManager.disconnect()
                        batchState.clearSelection()
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editState.beginCreateFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editState.beginCreateFile()
                } label: {
                    Image(systemName: "doc.badge.plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        let parent = SFTPBrowserPathHelper.parentPath(of: effectiveManager.currentPath)
                        _ = await effectiveManager.goToPath(parent)
                        batchState.clearSelection()
                    }
                } label: {
                    Image(systemName: "arrow.up.left")
                }
            }
            if effectiveManager.isUsingMockData {
                ToolbarItem(placement: .automatic) {
                    Text("模拟模式")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.15), in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 8)
        }
    }

    private var fileList: some View {
        List(effectiveManager.items) { item in
            SFTPFileRow(
                item: item,
                isSelected: batchState.contains(item),
                onToggleSelection: { toggleSelection(item) }
            )
                .contentShape(Rectangle())
                .onTapGesture {
                    if batchState.hasSelection {
                        toggleSelection(item)
                    } else if item.isDirectory {
                        Task { await effectiveManager.enterDirectory(item) }
                    }
                }
                .contextMenu {
                    Button("下载") {
                        Task {
                            let local = SFTPBrowserPathHelper.defaultDownloadURL(fileName: item.name)
                            await effectiveManager.download(item: item, to: local)
                        }
                    }

                    Button("删除", role: .destructive) {
                        Task { await effectiveManager.delete(item: item) }
                    }

                    Button("重命名") {
                        editState.beginRename(item)
                    }

                    Button("修改权限") {
                        editState.beginChmod(item)
                    }

                    Button(batchState.contains(item) ? "取消选择" : "选择") {
                        toggleSelection(item)
                    }
                }
        }
        .listStyle(.plain)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            SFTPDropUploadHandler.handle(providers: providers) { localURL in
                await effectiveManager.upload(localURL: localURL)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(8)
            }
        }
    }

    private var breadcrumbBar: some View {
        SFTPBreadcrumbBar(crumbs: pathCrumbs) { crumb in
            Task {
                await effectiveManager.goToPath(crumb.path)
                batchState.clearSelection()
            }
        }
    }

    private var summaryBar: some View {
        SFTPSummaryBar(
            itemCount: effectiveManager.items.count,
            directoryCount: effectiveManager.items.filter { $0.isDirectory }.count,
            fileCount: effectiveManager.items.filter { !$0.isDirectory }.count,
            currentPath: effectiveManager.currentPath
        )
    }

    private var pathCrumbs: [SFTPBreadcrumb] {
        SFTPBrowserPathHelper.breadcrumbs(for: effectiveManager.currentPath)
    }

    private var emptyFolderView: some View {
        SFTPEmptyFolderView()
    }

    private var selectedItems: [FileItem] {
        effectiveManager.items.filter { batchState.selectedIDs.contains($0.id) }
    }

    private func toggleSelection(_ item: FileItem) {
        batchState.toggleSelection(item)
    }

    private func performBatchDelete() async {
        let paths = SFTPBatchOperationFormatter.remotePaths(
            for: selectedItems,
            currentPath: effectiveManager.currentPath
        )
        let summary = await effectiveManager.batchDelete(paths: paths)
        batchState.clearSelection()
        batchState.showResult(SFTPBatchOperationFormatter.deleteResultMessage(for: summary))
    }

    private func performBatchDownload() async {
        let targets = SFTPBatchOperationFormatter.downloadableItems(from: selectedItems)
        guard !targets.isEmpty else {
            batchState.showResult(SFTPBatchOperationFormatter.noDownloadableFilesMessage)
            return
        }

        batchState.beginDownload(total: targets.count)

        let base = SFTPBrowserPathHelper.batchDownloadDirectory()

        let result = await effectiveManager.batchDownload(
            items: targets,
            destinationDirectory: base,
            maxConcurrent: 3
        ) { progress in
            Task { @MainActor in
                self.batchState.updateProgress(progress)
            }
        }

        batchState.finishBatch(message: SFTPBatchOperationFormatter.downloadResultMessage(for: result.summary))

#if os(macOS)
        if let first = result.downloadedURLs.first {
            revealInFinderURL = first
        }
#else
        if !result.downloadedURLs.isEmpty {
            shareURLs = result.downloadedURLs
            showingShareSheet = true
        }
#endif
    }

    private func autoBindActiveSessionIfNeeded() async {
        guard let active = sessionManager.activeSession else { return }
        guard active.isConnected, active.server.transport == .ssh else { return }
        if active.sftpManager.isConnected { return }
        guard let creds = try? vault.read(for: active.server.credentialID), !creds.isEmpty else { return }
        await active.sftpManager.connect(
            host: active.server.host,
            port: active.server.port,
            username: active.server.username,
            password: creds.password,
            privateKeyContent: creds.privateKeyContent,
            privateKeyPassphrase: creds.privateKeyPassphrase,
            allowPasswordFallback: active.server.allowPasswordFallback,
            preferMock: false
        )
    }
}
