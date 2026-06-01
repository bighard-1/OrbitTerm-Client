import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct SFTPBrowserView: View {
    @StateObject private var manager = SFTPManager()
    @ObservedObject private var sessionManager = SessionManager.shared
    private let vault = CredentialVault.shared

    @State private var host: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var preferMockMode: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var editState = SFTPBrowserEditState()

    @State private var selectedIDs: Set<String> = []
    @State private var showingBatchDeleteConfirm = false
    @State private var isBatchRunning = false
    @State private var batchProgress: BatchDownloadProgress?
    @State private var batchResultMessage: String = ""
    @State private var showingBatchResult = false

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
            effectiveManager.activateMockIfNeeded(host: host, username: username, password: password)
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
        .alert("确认批量删除", isPresented: $showingBatchDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await performBatchDelete() }
            }
        } message: {
            Text("即将删除 \(selectedItems.count) 项，删除后不可恢复。")
        }
        .alert("批量操作结果", isPresented: $showingBatchResult) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(batchResultMessage)
        }
#if os(iOS)
        .sheet(isPresented: $showingShareSheet) {
            ActivityShareSheet(activityItems: shareURLs)
        }
#endif
    }

    private var connectPanel: some View {
        Form {
            Section("连接信息") {
                TextField("主机或 IP", text: $host)
                    .applyInputPolish()
                TextField("用户名", text: $username)
                    .applyInputPolish()
                SecureField("密码", text: $password)
            }

            Section("模式") {
                Toggle("优先使用模拟数据", isOn: $preferMockMode)
                Text("若未配置 SSH，系统会自动进入 Mock 文件列表。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("操作") {
                Button(preferMockMode ? "进入模拟浏览" : "连接 SFTP") {
                    Task {
                        await effectiveManager.connect(
                            host: host,
                            username: username,
                            password: password,
                            preferMock: preferMockMode
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

                if !selectedIDs.isEmpty {
                    SFTPBatchToolbar(
                        selectedCount: selectedIDs.count,
                        progress: batchProgress,
                        isRunning: isBatchRunning,
                        onCancel: { selectedIDs.removeAll() },
                        onDownload: { Task { await performBatchDownload() } },
                        onDelete: { showingBatchDeleteConfirm = true }
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
                        selectedIDs.removeAll()
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("断开") {
                    Task {
                        await effectiveManager.disconnect()
                        selectedIDs.removeAll()
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
                        selectedIDs.removeAll()
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
                isSelected: selectedIDs.contains(item.id),
                onToggleSelection: { toggleSelection(item) }
            )
                .contentShape(Rectangle())
                .onTapGesture {
                    if !selectedIDs.isEmpty {
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

                    Button(selectedIDs.contains(item.id) ? "取消选择" : "选择") {
                        toggleSelection(item)
                    }
                }
        }
        .listStyle(.plain)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
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
                selectedIDs.removeAll()
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
        effectiveManager.items.filter { selectedIDs.contains($0.id) }
    }

    private func toggleSelection(_ item: FileItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    private func performBatchDelete() async {
        let paths = SFTPBatchOperationFormatter.remotePaths(
            for: selectedItems,
            currentPath: effectiveManager.currentPath
        )
        let summary = await effectiveManager.batchDelete(paths: paths)
        selectedIDs.removeAll()
        batchResultMessage = SFTPBatchOperationFormatter.deleteResultMessage(for: summary)
        showingBatchResult = true
    }

    private func performBatchDownload() async {
        let targets = SFTPBatchOperationFormatter.downloadableItems(from: selectedItems)
        guard !targets.isEmpty else {
            batchResultMessage = SFTPBatchOperationFormatter.noDownloadableFilesMessage
            showingBatchResult = true
            return
        }

        isBatchRunning = true
        batchProgress = BatchDownloadProgress(completed: 0, total: targets.count, bytesTransferred: 0, currentFile: "")

        let base = SFTPBrowserPathHelper.batchDownloadDirectory()

        let result = await effectiveManager.batchDownload(
            items: targets,
            destinationDirectory: base,
            maxConcurrent: 3
        ) { progress in
            Task { @MainActor in
                self.batchProgress = progress
            }
        }

        isBatchRunning = false
        selectedIDs.removeAll()

        batchResultMessage = SFTPBatchOperationFormatter.downloadResultMessage(for: result.summary)
        showingBatchResult = true

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

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let accepted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !accepted.isEmpty else { return false }

        for provider in accepted {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                Task { @MainActor in
                    await effectiveManager.upload(localURL: url)
                }
            }
        }

        return true
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

#if os(iOS)
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}
#endif
