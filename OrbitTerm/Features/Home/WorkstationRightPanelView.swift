import SwiftUI
import UniformTypeIdentifiers

enum WorkstationRightPanelTab: String, CaseIterable, Identifiable {
    case sftp
    case docker
    case snippets

    var id: Self { self }

    var title: String {
        switch self {
        case .sftp: "SFTP"
        case .docker: "Docker"
        case .snippets: "Snippets"
        }
    }

    var systemImage: String {
        switch self {
        case .sftp: "folder"
        case .docker: "shippingbox"
        case .snippets: "text.badge.plus"
        }
    }
}

struct WorkstationRightPanelView: View {
    @Environment(\.appThemePalette) private var palette
    @ObservedObject var sessionManager: SessionManager
    @ObservedObject var snippetStore: SnippetStore

    @Binding var selectedTab: WorkstationRightPanelTab
    @Binding var sftpPathFocusRequest: Int
    @State private var showingSFTPUploadImporter = false

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
        ) { result in
            guard case let .success(urls) = result,
                  let active = sessionManager.activeSession else {
                return
            }
            Task {
                await uploadSelectedSFTPFiles(urls, to: active.sftpManager)
            }
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
                .accessibilityLabel("SFTP 工具内容")
        case .docker:
            ScrollView(.vertical, showsIndicators: true) {
                dockerSection(active)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            }
            .accessibilityLabel("Docker 工具内容")
        case .snippets:
            ScrollView(.vertical, showsIndicators: true) {
                snippetsSection(active)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            }
            .accessibilityLabel("Snippets 工具内容")
        }
    }

    @ViewBuilder
    private func sftpSection(_ active: WorkspaceSession) -> some View {
        if active.terminalSplitCount > 0 {
            WorkstationCollapsedFeatureRow(title: "SFTP（分屏模式已禁用同步）") { }
        } else {
            WorkstationSFTPCardView(
                sftpManager: active.sftpManager,
                onRefresh: {
                    Task { try? await active.sftpManager.refresh() }
                },
                onUpload: {
                    showingSFTPUploadImporter = true
                },
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
                }
            )
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

    @ViewBuilder
    private func snippetsSection(_ active: WorkspaceSession) -> some View {
        WorkstationSnippetsCardView(
            active: active,
            snippetStore: snippetStore,
            onInsertCommand: { command, executeImmediately in
                Task {
                    await sessionManager.dispatchSnippetCommand(
                        session: active,
                        command: command,
                        executeImmediately: executeImmediately
                    )
                }
            }
        )
    }

    private var emptyState: some View {
        Text("连接终端后自动展示监控与 SFTP")
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

    private func uploadSelectedSFTPFiles(_ urls: [URL], to manager: SFTPManager) async {
        for url in urls {
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory != true else {
                manager.statusText = "上传失败: 暂不支持直接上传文件夹"
                continue
            }
            await manager.upload(localURL: url)
        }
    }
}
