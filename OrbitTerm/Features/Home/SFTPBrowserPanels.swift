import SwiftUI
import UniformTypeIdentifiers

struct SFTPConnectPanel: View {
    @Binding var draft: SFTPBrowserConnectionDraft
    @ObservedObject var manager: SFTPManager
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        Form {
            Section("连接信息") {
                TextField("主机或 IP", text: $draft.host)
                    .applyInputPolish()
                TextField("用户名", text: $draft.username)
                    .applyInputPolish()
                SecureField("密码", text: $draft.password)
            }

            #if !ORBITTERM_PUBLIC_RELEASE
            Section("开发测试") {
                Toggle("优先使用模拟数据", isOn: $draft.preferMockMode)
                Text("仅开发与 UI 测试构建可使用模拟目录；Release 不会提供该入口。")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
            }
            #endif

            Section("操作") {
                Button(sftpConnectButtonTitle) {
                    Task {
                        await manager.connect(
                            host: draft.host,
                            username: draft.username,
                            password: draft.password,
                            preferMock: draft.preferMockMode
                        )
                    }
                }
                .buttonStyle(ThemedPrimaryButtonStyle())
                .disabled(manager.isLoading)
            }

            if !manager.statusText.isEmpty {
                Section("状态") {
                    Text(manager.statusText)
                        .foregroundStyle(palette.textSecondary.color)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .orbitTermClearTransientSensitiveInput)) { _ in
            draft.password = ""
        }
    }

    private var sftpConnectButtonTitle: String {
        #if !ORBITTERM_PUBLIC_RELEASE
        draft.preferMockMode ? "进入模拟浏览" : "连接 SFTP"
        #else
        "连接 SFTP"
        #endif
    }
}

struct SFTPVerifiedSessionPanel: View {
    let hasVerifiedSession: Bool
    let isLoading: Bool
    let statusText: String
    let recovery: OperationRecoveryPresentation?
    let onOpen: () -> Void
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security

    var body: some View {
        ContentUnavailableView {
            Label(
                hasVerifiedSession ? "安全打开 SFTP" : "需要已验证会话",
                systemImage: hasVerifiedSession ? "lock.shield" : "exclamationmark.shield"
            )
        } description: {
            Text(
                hasVerifiedSession
                    ? "SFTP 将复用当前已验证的 SSH 会话，不会读取或重新发送主机凭据。"
                    : "请先在终端页建立已验证的 SSH 会话，然后再打开 SFTP。"
            )
        } actions: {
            if hasVerifiedSession {
                Button("打开 SFTP", action: onOpen)
                .buttonStyle(ThemedPrimaryButtonStyle())
                    .disabled(isLoading)
            }
            if isLoading {
                ProgressView()
            } else if let recovery {
                Label(recovery.message, systemImage: recovery.systemImage)
                    .font(.caption)
                    .foregroundStyle(recovery.severity == .danger ? security.danger.color : security.warning.color)
                    .accessibilityLabel("SFTP：\(recovery.title)。\(recovery.message)")
            } else if !statusText.isEmpty, statusText != "未连接" {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
            }
        }
    }
}

struct SFTPFileListView: View {
    @ObservedObject var manager: SFTPManager
    @Binding var batchState: SFTPBrowserBatchState
    @Binding var editState: SFTPBrowserEditState
    @Binding var isDropTargeted: Bool
    let onDownload: (FileItem) async -> Void
    let onDelete: (FileItem) async -> Void
    let onEnterDirectory: (FileItem) async -> Void
    let onOpen: (FileItem) async -> Void
    let onUpload: (URL) async -> Void
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        ScrollViewReader { proxy in
            List(manager.items) { item in
                SFTPFileRow(
                    item: item,
                    isSelected: batchState.contains(item),
                    isPathTarget: manager.highlightedItemID == item.id,
                    onToggleSelection: { toggleSelection(item) }
                )
                .id(item.id)
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowBackground(palette.surfaceReadable.color)
                .contentShape(Rectangle())
                .onTapGesture {
                    if batchState.hasSelection {
                        toggleSelection(item)
                    } else if item.isDirectory {
                        Task { await onEnterDirectory(item) }
                    } else {
                        Task { await onOpen(item) }
                    }
                }
                .contextMenu {
                    if !item.isDirectory {
                        Button("在应用内打开") {
                            Task { await onOpen(item) }
                        }
                    }

                    Button("下载") {
                        Task { await onDownload(item) }
                    }

                    Button("删除", role: .destructive) {
                        Task { await onDelete(item) }
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
            .scrollContentBackground(.hidden)
            .background(palette.surfaceReadable.color)
            .onChange(of: manager.highlightedItemID) { _, itemID in
                guard let itemID else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(itemID, anchor: .center)
                }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            SFTPDropUploadHandler.handle(providers: providers) { localURL in
                await onUpload(localURL)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(palette.focusRing.color, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(8)
            }
        }
    }

    private func toggleSelection(_ item: FileItem) {
        batchState.toggleSelection(item)
    }
}
