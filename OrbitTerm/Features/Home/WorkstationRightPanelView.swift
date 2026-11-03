import SwiftUI
import UniformTypeIdentifiers

enum WorkstationRightPanelTab: String, CaseIterable, Identifiable {
    case sftp
    case docker

    var id: Self { self }

    var title: String {
        switch self {
        case .sftp: "SFTP"
        case .docker: "Docker"
        }
    }

    var systemImage: String {
        switch self {
        case .sftp: "folder"
        case .docker: "shippingbox"
        }
    }
}

struct WorkstationRightPanelView: View {
    @Environment(\.appThemePalette) private var palette
    @ObservedObject var sessionManager: SessionManager

    @Binding var selectedTab: WorkstationRightPanelTab
    @Binding var sftpPathFocusRequest: Int
    @State private var showingSFTPUploadImporter = false
    @State private var uploadSelection: SFTPUploadSelectionContext?
    @State private var uploadManager: SFTPManager?
    @StateObject private var uploadQueue = SFTPUploadQueueController()

    let onCollapse: () -> Void
    let onCreateSFTPItem: (UUID, SFTPCreateKind) -> Void
    let onRenameSFTPItem: (UUID, FileItem) -> Void
    let onChmodSFTPItem: (UUID, FileItem) -> Void
    let onOpenSFTPFile: (UUID, FileItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let active = sessionManager.activeSession {
                featurePicker
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                ThemedDivider()

                featureContent(active)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                emptyState
                    .padding(12)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .background(palette.surfaceReadable.color)
        .fileImporter(
            isPresented: $showingSFTPUploadImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { handleSelectedSFTPFiles($0) }
        .onDisappear { cancelFileUpload() }
        .onChange(of: sessionManager.activeTabID) { _, _ in cancelFileUpload() }
        .onChange(of: selectedTab) { _, tab in
            if tab != .sftp { cancelFileUpload() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("会话工具")
                    .font(.headline)
                Spacer()
                Button {
                    onCollapse()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("收起右侧工具栏")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var featurePicker: some View {
        Picker("下方工具面板", selection: $selectedTab) {
            ForEach(WorkstationRightPanelTab.allCases) { tab in
                Label(tab.title, systemImage: tab.systemImage).tag(tab)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .tint(palette.accentPrimary.color)
        .accessibilityLabel("下方工具面板")
        .padding(.top, 2)
    }

    @ViewBuilder
    private func featureContent(_ active: WorkspaceSession) -> some View {
        switch selectedTab {
        case .sftp:
            sftpSection(active)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("SFTP 工具内容")
        case .docker:
            ScrollView(.vertical, showsIndicators: true) {
                dockerSection(active)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Docker 工具内容")
        }
    }

    @ViewBuilder
    private func sftpSection(_ active: WorkspaceSession) -> some View {
        if active.terminalSplitCount > 0 {
            WorkstationCollapsedFeatureRow(title: "SFTP（分屏模式已禁用同步）") { }
        } else {
            WorkstationSFTPCardView(
                sftpManager: active.sftpManager,
                isUploadRunning: uploadQueue.isRunning,
                onRefresh: {
                    Task { try? await active.sftpManager.refresh() }
                },
                onUpload: {
                    beginFileUpload(active)
                },
                onUploadContextInvalidated: { cancelFileUpload() },
                onCreateDirectory: {
                    onCreateSFTPItem(active.id, .directory)
                },
                onCreateFile: {
                    onCreateSFTPItem(active.id, .file)
                },
                onUp: {
                    Task {
                        await goToParentDirectory(active)
                    }
                },
                onNavigateToPath: { path in
                    guard await active.sftpManager.navigateToPath(path) else { return false }
                    await sessionManager.syncTerminalPathFromSFTP(
                        session: active,
                        newPath: active.sftpManager.currentPath
                    )
                    return true
                },
                pathFocusRequest: sftpPathFocusRequest,
                onEnterDirectory: { item in
                    Task {
                        await active.sftpManager.enterDirectory(item)
                        await sessionManager.syncTerminalPathFromSFTP(session: active, newPath: active.sftpManager.currentPath)
                    }
                },
                onOpenFile: { item in
                    onOpenSFTPFile(active.id, item)
                },
                onDownload: { item in
                    Task {
                        let dst = desktopURL(fileName: item.name)
                        await active.sftpManager.download(item: item, to: dst)
                    }
                },
                onBatchDownload: { items in
                    await active.sftpManager.batchDownload(
                        items: items,
                        destinationDirectory: SFTPBrowserPathHelper.batchDownloadDirectory(),
                        maxConcurrent: OperationResourceBudget.sftpMaximumConcurrentTransfers
                    )
                },
                onRename: { item in
                    onRenameSFTPItem(active.id, item)
                },
                onChmod: { item in
                    onChmodSFTPItem(active.id, item)
                },
                onSetMode: { item, mode in
                    Task { await active.sftpManager.chmod(item: item, modeOctal: mode) }
                },
                onDelete: { item in
                    Task { await active.sftpManager.delete(item: item) }
                },
                onBatchDelete: { items in
                    let paths = SFTPBatchOperationFormatter.remotePaths(
                        for: items,
                        currentPath: active.sftpManager.currentPath
                    )
                    _ = await active.sftpManager.batchDelete(paths: paths)
                }
            )
            .id(active.id)
        }
    }

    @ViewBuilder
    private func dockerSection(_ active: WorkspaceSession) -> some View {
        WorkstationDockerCardView(
            active: active,
            dockerService: active.dockerService,
            onStartCheckedDocker: {
                Task { await sessionManager.startDockerForActiveSessionIfNeeded() }
            }
        )
    }

    private var emptyState: some View {
        Text("连接会话后自动显示 SFTP 与 Docker")
            .font(.caption)
            .foregroundStyle(palette.textSecondary.color)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themedReadableSurface()
    }

    private func goToParentDirectory(_ active: WorkspaceSession) async {
        let current = active.sftpManager.currentPath
        let parent: String
        if current == "/" {
            parent = "/"
        } else {
            let deletingLast = (current as NSString).deletingLastPathComponent
            parent = deletingLast.isEmpty ? "/" : deletingLast
        }
        await active.sftpManager.goToPath(parent)
        await sessionManager.syncTerminalPathFromSFTP(session: active, newPath: active.sftpManager.currentPath)
    }

    private func desktopURL(fileName: String) -> URL {
#if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
#else
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return docs.appendingPathComponent(fileName, isDirectory: false)
#endif
    }

    private func beginFileUpload(_ active: WorkspaceSession) {
        let target = active.sftpManager
        guard target.isConnected, !uploadQueue.isRunning,
              let context = SFTPUploadSelectionContext(
                workspaceID: active.id, sessionID: target.activeSessionID, directory: target.currentPath
              ) else { return }
        uploadManager = target
        uploadSelection = context
        showingSFTPUploadImporter = true
    }

    private func handleSelectedSFTPFiles(_ result: Result<[URL], Error>) {
        guard let target = uploadManager, let context = uploadSelection else { return }
        uploadManager = nil
        uploadSelection = nil
        guard target === sessionManager.activeSession?.sftpManager, target.isConnected,
              context.matches(workspaceID: sessionManager.activeTabID,
                              sessionID: target.activeSessionID, directory: target.currentPath) else { return }
        let urls: [URL]
        switch result {
        case let .success(selected): urls = selected
        case let .failure(error):
            let cocoaError = error as NSError
            if cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == NSUserCancelledError { return }
            target.statusText = "上传失败: 无法读取所选文件，请重新选择"
            return
        }
        uploadQueue.start(urls: urls, canContinue: {
            target === sessionManager.activeSession?.sftpManager && target.isConnected &&
                context.matches(workspaceID: sessionManager.activeTabID,
                                sessionID: target.activeSessionID, directory: target.currentPath)
        }, operation: { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let remotePath = context.remotePath(fileName: url.lastPathComponent) else {
                target.statusText = "上传失败: 请选择可读取的普通文件，暂不支持文件夹"
                return
            }
            await target.upload(localURL: url, remotePath: remotePath)
        })
    }

    private func cancelFileUpload() {
        uploadQueue.abandon()
        uploadManager = nil
        uploadSelection = nil
        showingSFTPUploadImporter = false
    }
}
