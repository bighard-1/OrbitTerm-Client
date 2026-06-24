import SwiftUI

struct WorkstationRightPanelView: View {
    @ObservedObject var sessionManager: SessionManager
    @ObservedObject var snippetStore: SnippetStore

    @Binding var showMonitorPanel: Bool
    @Binding var showSFTPPanel: Bool
    @Binding var showDockerPanel: Bool
    @Binding var showSnippetsPanel: Bool
    @Binding var showingMonitorDetailPanelID: UUID?

    let onCollapse: () -> Void
    let onCreateSFTPItem: (UUID, SFTPCreateKind) -> Void
    let onRenameSFTPItem: (UUID, FileItem) -> Void
    let onChmodSFTPItem: (UUID, FileItem) -> Void
    let onOpenSFTPFile: (UUID, FileItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    if let active = sessionManager.activeSession {
                        activeSessionContent(active)
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack {
            Text("监控 + SFTP")
                .font(.headline)
            Spacer()
            Button {
                onCollapse()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func activeSessionContent(_ active: WorkspaceSession) -> some View {
        monitorSection(active)
        sftpSection(active)
        dockerSection(active)
        snippetsSection(active)
    }

    @ViewBuilder
    private func monitorSection(_ active: WorkspaceSession) -> some View {
        if showMonitorPanel {
            WorkstationMonitorCardView(
                active: active,
                monitorService: sessionManager.monitorService,
                isDetailShown: showingMonitorDetailPanelID == active.activeMonitorPanelID,
                onHide: { showMonitorPanel = false },
                onShowDetail: {
                    if let panelID = active.activeMonitorPanelID {
                        showingMonitorDetailPanelID = panelID
                    }
                },
                onHideDetail: { showingMonitorDetailPanelID = nil },
                onStartCheckedMonitoring: {
                    Task { await sessionManager.startMonitorForActiveSessionIfNeeded() }
                }
            )
            if let panelID = showingMonitorDetailPanelID,
               panelID == active.activeMonitorPanelID {
                MonitorDetailInlineView(
                    panelID: panelID,
                    service: sessionManager.monitorService,
                    onClose: { showingMonitorDetailPanelID = nil }
                )
            }
        } else {
            WorkstationCollapsedFeatureRow(title: "系统监控") { showMonitorPanel = true }
        }
    }

    @ViewBuilder
    private func sftpSection(_ active: WorkspaceSession) -> some View {
        if active.terminalSplitCount > 0 {
            WorkstationCollapsedFeatureRow(title: "SFTP（分屏模式已禁用同步）") { }
        } else if showSFTPPanel {
            WorkstationSFTPCardView(
                active: active,
                onHide: { showSFTPPanel = false },
                onRefresh: {
                    Task { try? await active.sftpManager.refresh() }
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
        } else {
            WorkstationCollapsedFeatureRow(title: "SFTP") { showSFTPPanel = true }
        }
    }

    @ViewBuilder
    private func dockerSection(_ active: WorkspaceSession) -> some View {
        if showDockerPanel {
            WorkstationDockerCardView(
                active: active,
                onHide: { showDockerPanel = false },
                onStartCheckedDocker: {
                    Task { await sessionManager.startDockerForActiveSessionIfNeeded() }
                }
            )
        } else {
            WorkstationCollapsedFeatureRow(title: "Docker") { showDockerPanel = true }
        }
    }

    @ViewBuilder
    private func snippetsSection(_ active: WorkspaceSession) -> some View {
        if showSnippetsPanel {
            WorkstationSnippetsCardView(
                active: active,
                snippetStore: snippetStore,
                onHide: { showSnippetsPanel = false },
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
        } else {
            WorkstationCollapsedFeatureRow(title: "Snippets") { showSnippetsPanel = true }
        }
    }

    private var emptyState: some View {
        Text("连接终端后自动展示监控与 SFTP")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
}
