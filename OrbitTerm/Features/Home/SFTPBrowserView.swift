import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SFTPBrowserView: View {
    @StateObject private var manager = SFTPManager()
    @ObservedObject private var sessionManager = SessionManager.shared
    @Environment(\.appThemePalette) private var palette

    @State private var connectionDraft = SFTPBrowserConnectionDraft()
    @State private var pathInput = ""
    @State private var isDropTargeted: Bool = false
    @State private var editState = SFTPBrowserEditState()
    @State private var batchState = SFTPBrowserBatchState()
    @State private var batchDownloadTask: Task<Void, Never>?
    @State private var batchDownloadGeneration = UUID()
    @State private var documentOperationGeneration = UUID()
    @State private var showDocumentDiscardConfirmation = false
    @State private var hiddenOperationStatusText: String?

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
        ZStack {
            AppChromeBackground()

            VStack(spacing: 0) {
                if !effectiveManager.isConnected {
                    if sessionManager.requiresCheckedConnection {
                        SFTPVerifiedSessionPanel(
                            hasVerifiedSession: sessionManager.activeSession?.verifiedSessionLease != nil,
                            isLoading: effectiveManager.isLoading,
                            statusText: effectiveManager.statusText,
                            recovery: effectiveManager.recoveryPresentation,
                            onOpen: {
                                Task { await autoBindActiveSessionIfNeeded() }
                            }
                        )
                    } else {
                        SFTPConnectPanel(draft: $connectionDraft, manager: effectiveManager)
                    }
                } else {
                    browserPanel
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("SFTP")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task {
            manager.configureConnectionMode(sessionManager.connectionSecurityPolicy)
            #if !ORBITTERM_PUBLIC_RELEASE
            if sessionManager.connectionSecurityPolicy.allowsLegacyNetwork {
                effectiveManager.activateMockIfNeeded(
                    host: connectionDraft.host,
                    username: connectionDraft.username,
                    password: connectionDraft.password
                )
            }
            #endif
            await autoBindActiveSessionIfNeeded()
        }
        .task(id: effectiveManager.statusText) {
            hiddenOperationStatusText = nil
            guard operationStatusShouldBePresented, !operationStatusIsFailure,
                  let delay = OperationalFeedbackPolicy.lifetime(kind: .success).autoDismissAfterNanoseconds else {
                return
            }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            hiddenOperationStatusText = effectiveManager.statusText
        }
        .onDisappear {
            cancelBatchDownload()
            cancelDocumentOperation()
        }
        .onChange(of: sessionManager.activeTabID) { _, _ in
            // A transfer belongs to the session that started it. Do not let a
            // hidden/previous tab keep publishing progress into this shared UI.
            cancelBatchDownload()
            cancelDocumentOperation()
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
        .sheet(isPresented: Binding(
            get: { editState.document != nil },
            set: { if !$0 { editState.closeDocument() } }
        )) {
            documentSheet
        }
    }

    private var browserPanel: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                SFTPPathNavigator(
                    path: $pathInput,
                    isEnabled: effectiveManager.activeSessionID != nil,
                    onNavigate: navigateToPath
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                breadcrumbBar
                summaryBar
                Label(
                    operationalPresentation.headline,
                    systemImage: operationalPresentation.phase == .failed
                        ? "exclamationmark.triangle.fill"
                        : "circle.fill"
                )
                .font(.caption)
                .foregroundStyle(operationalPresentation.phase == .failed ? Color.red : palette.textSecondary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .accessibilityLabel("SFTP：\(operationalPresentation.headline)。\(operationalPresentation.detail)")
                if shouldShowOperationStatus {
                    Group {
                        if operationStatusIsFailure {
                            OperationalFailureBanner(
                                content: operationalPresentation,
                                action: operationalActionPresentation,
                                accessibilityPrefix: "SFTP"
                            )
                        } else {
                            OperationalTransientSuccessBanner(message: effectiveManager.statusText)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }

                if effectiveManager.isLoading && effectiveManager.items.isEmpty {
                    ProgressView(operationalPresentation.headline)
                        .tint(palette.accentPrimary.color)
                        .foregroundStyle(palette.textPrimary.color)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if effectiveManager.items.isEmpty {
                    emptyFolderView
                } else {
                    fileList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            VStack(spacing: 8) {
                if effectiveManager.isLoading && !effectiveManager.items.isEmpty {
                    ProgressView("正在更新目录…")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .accessibilityLabel("正在更新 SFTP 目录，现有列表仍可查看")
                }
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
                        onCancel: { cancelBatchDownload() },
                        onDownload: { startBatchDownload() },
                        onDelete: { batchState.requestDeleteConfirmation() }
                    )
                        .padding(.horizontal, 12)
                }

                SFTPTransferBoard(manager: effectiveManager)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                OperationalRefreshButton(presentation: operationalActionPresentation) {
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
            #if !ORBITTERM_PUBLIC_RELEASE
            if effectiveManager.isUsingMockData {
                ToolbarItem(placement: .automatic) {
                    Text("模拟模式")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(palette.accentPrimary.color)
                        .background(palette.surfaceInput.color, in: Capsule())
                }
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 8)
        }
    }

    private var fileList: some View {
        SFTPFileListView(
            manager: effectiveManager,
            batchState: $batchState,
            editState: $editState,
            isDropTargeted: $isDropTargeted,
            onDownload: { item in
                let local = SFTPBrowserPathHelper.defaultDownloadURL(fileName: item.name)
                await effectiveManager.download(item: item, to: local)
            },
            onDelete: { item in
                await effectiveManager.delete(item: item)
            },
            onEnterDirectory: { item in
                await effectiveManager.enterDirectory(item)
            },
            onOpen: { item in
                await openDocument(item)
            },
            onUpload: { localURL in
                await effectiveManager.upload(localURL: localURL)
            }
        )
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

    private var operationStatusIsFailure: Bool {
        let text = effectiveManager.statusText
        return text.contains("失败")
            || text.contains("不可写")
            || text.contains("权限不足")
            || text.contains("没有权限")
            || text.contains("拒绝")
    }

    private var operationalPresentation: OperationalContentPresentation {
        let failureDetail = effectiveManager.recoveryPresentation?.message
            ?? (operationStatusIsFailure ? effectiveManager.statusText : nil)
        return OperationalContentPresentationMapper.sftp(
            isLoading: effectiveManager.isLoading,
            hasItems: !effectiveManager.items.isEmpty,
            failureDetail: failureDetail
        )
    }

    private var operationalActionPresentation: OperationalActionPresentation {
        OperationalContentPresentationMapper.refreshAction(
            module: .sftp,
            phase: operationalPresentation.phase,
            isRefreshing: effectiveManager.isLoading,
            hasContent: !effectiveManager.items.isEmpty
        )
    }

    private var shouldShowOperationStatus: Bool {
        operationStatusShouldBePresented && hiddenOperationStatusText != effectiveManager.statusText
    }

    private var operationStatusShouldBePresented: Bool {
        let text = effectiveManager.statusText
        return text.contains("已创建")
            || text.contains("新建")
            || text.contains("同名")
            || operationStatusIsFailure
            || operationalPresentation.phase == .failed
    }

    private func navigateToPath() {
        let requestedPath = pathInput
        Task {
            if await effectiveManager.navigateToPath(requestedPath) {
                pathInput = effectiveManager.currentPath
                batchState.clearSelection()
            }
        }
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

    private func startBatchDownload() {
        guard batchDownloadTask == nil else { return }
        let generation = UUID()
        let transferManager = effectiveManager
        batchDownloadGeneration = generation
        batchDownloadTask = Task {
            await performBatchDownload(
                generation: generation,
                manager: transferManager
            )
            guard batchDownloadGeneration == generation else { return }
            batchDownloadTask = nil
        }
    }

    private func cancelBatchDownload() {
        batchDownloadGeneration = UUID()
        batchDownloadTask?.cancel()
        batchDownloadTask = nil
        if batchState.isRunning {
            batchState.cancelBatch()
        } else {
            batchState.clearSelection()
        }
    }

    private func openDocument(_ item: FileItem) async {
        guard !item.isDirectory else { return }
        let generation = UUID()
        let documentManager = effectiveManager
        let sessionID = documentManager.activeSessionID
        let path = documentManager.currentPath
        documentOperationGeneration = generation
        documentManager.statusText = "正在应用内打开 (item.name)…"
        do {
            let content = try await documentManager.readTextFile(item: item)
            guard documentOperationGeneration == generation,
                  effectiveManager === documentManager,
                  documentManager.activeSessionID == sessionID,
                  documentManager.currentPath == path else { return }
            editState.presentDocument(item: item, content: content)
            documentManager.statusText = "已在应用内打开 (item.name)"
        } catch {
            guard documentOperationGeneration == generation,
                  effectiveManager === documentManager else { return }
            documentManager.statusText = "应用内打开失败：(error.localizedDescription)"
        }
    }

    private func saveDocument() {
        guard let document = editState.document, !document.isSaving else { return }
        let generation = documentOperationGeneration
        let documentManager = effectiveManager
        editState.setDocumentSaving(true)
        Task {
            do {
                try await documentManager.writeTextFile(
                    item: document.item,
                    content: document.textFormat.serialize(document.draftContent)
                )
                guard documentOperationGeneration == generation,
                      effectiveManager === documentManager else { return }
                editState.closeDocument()
            } catch {
                guard documentOperationGeneration == generation,
                      effectiveManager === documentManager else { return }
                editState.setDocumentError(error.localizedDescription)
            }
        }
    }

    private func cancelDocumentOperation() {
        documentOperationGeneration = UUID()
        editState.closeDocument()
    }

    @ViewBuilder
    private var documentSheet: some View {
        NavigationStack {
            ZStack {
                AppChromeBackground()
                if let document = editState.document {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(
                                document.mode == .editing ? "编辑模式" : "只读预览",
                                systemImage: document.mode == .editing ? "pencil" : "eye"
                            )
                            .font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(document.textFormat.displayLabel) · 最大 2 MB")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let errorMessage = document.errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .accessibilityLabel("保存失败。\(errorMessage)")
                        }

                        if document.mode == .editing {
                            Text("自动折行仅改变屏幕显示；只有手动换行会写入远端文件。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextEditor(text: Binding(
                                get: { editState.document?.draftContent ?? "" },
                                set: { editState.updateDocumentDraft($0) }
                            ))
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .themedInputSurface(focused: true)
                            .disabled(document.isSaving)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollView {
                                Text(document.draftContent.isEmpty ? "（空文件）" : document.draftContent)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .padding(12)
                            }
                            .themedReadableSurface()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(editState.document?.item.name ?? "文件")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        if editState.document?.hasUnsavedChanges == true {
                            showDocumentDiscardConfirmation = true
                        } else {
                            editState.closeDocument()
                        }
                    }
                    .disabled(editState.document?.isSaving == true)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if editState.document?.mode == .editing {
                        Button(editState.document?.isSaving == true ? "保存中…" : "保存") {
                            saveDocument()
                        }
                        .disabled(editState.document?.isSaving == true)
                    } else {
                        Button("编辑") { editState.beginDocumentEditing() }
                    }
                }
            }
            .alert("放弃未保存的编辑？", isPresented: $showDocumentDiscardConfirmation) {
                Button("继续编辑", role: .cancel) {}
                Button("放弃", role: .destructive) { editState.closeDocument() }
            } message: {
                Text("远端文件不会被修改。")
            }
        }
    }

    private func performBatchDownload(
        generation: UUID,
        manager: SFTPManager
    ) async {
        let targets = SFTPBatchOperationFormatter.downloadableItems(from: selectedItems)
        guard !targets.isEmpty else {
            batchState.showResult(SFTPBatchOperationFormatter.noDownloadableFilesMessage)
            return
        }

        batchState.beginDownload(total: targets.count)

        let base = SFTPBrowserPathHelper.batchDownloadDirectory()

        let result = await manager.batchDownload(
            items: targets,
            destinationDirectory: base,
            maxConcurrent: OperationResourceBudget.sftpMaximumConcurrentTransfers
        ) { progress in
            Task { @MainActor in
                guard self.batchDownloadGeneration == generation else { return }
                self.batchState.updateProgress(progress)
            }
        }

        guard !Task.isCancelled, batchDownloadGeneration == generation else {
            return
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
        await sessionManager.openSFTPForActiveSessionIfNeeded(standaloneManager: manager)
    }
}
