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

            Section("模式") {
                Toggle("优先使用模拟数据", isOn: $draft.preferMockMode)
                Text("若未配置 SSH，系统会自动进入 Mock 文件列表。")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
            }

            Section("操作") {
                Button(draft.preferMockMode ? "进入模拟浏览" : "连接 SFTP") {
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
    }
}

struct SFTPVerifiedSessionPanel: View {
    let hasVerifiedSession: Bool
    let isLoading: Bool
    let statusText: String
    let onOpen: () -> Void
    @Environment(\.appThemePalette) private var palette

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
    let onUpload: (URL) async -> Void
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        List(manager.items) { item in
            SFTPFileRow(
                item: item,
                isSelected: batchState.contains(item),
                onToggleSelection: { toggleSelection(item) }
            )
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            .listRowBackground(palette.surfaceReadable.color)
            .contentShape(Rectangle())
            .onTapGesture {
                if batchState.hasSelection {
                    toggleSelection(item)
                } else if item.isDirectory {
                    Task { await onEnterDirectory(item) }
                }
            }
            .contextMenu {
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
