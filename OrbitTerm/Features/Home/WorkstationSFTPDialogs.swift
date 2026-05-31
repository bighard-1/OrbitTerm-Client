import SwiftUI

enum SFTPCreateKind {
    case file
    case directory
}

struct PendingSFTPRename: Identifiable {
    let sessionID: UUID
    let item: FileItem
    var id: String { "\(sessionID.uuidString)::\(item.id)" }
}

struct PendingSFTPCreate: Identifiable {
    let sessionID: UUID
    let kind: SFTPCreateKind
    let id = UUID()
}

struct PendingSFTPChmod: Identifiable {
    let sessionID: UUID
    let item: FileItem
    let id = UUID()
}

struct PendingSFTPFileEdit: Identifiable {
    let sessionID: UUID
    let item: FileItem
    var id: String { "\(sessionID.uuidString)::\(item.id)" }
}

struct WorkstationSFTPDialogs: ViewModifier {
    @ObservedObject var sessionManager: SessionManager
    @Binding var pendingRename: PendingSFTPRename?
    @Binding var renameText: String
    @Binding var pendingCreate: PendingSFTPCreate?
    @Binding var createText: String
    @Binding var pendingChmod: PendingSFTPChmod?
    @Binding var chmodText: String
    @Binding var pendingFileEdit: PendingSFTPFileEdit?
    @Binding var fileEditContent: String
    @Binding var fileEditStatus: String
    @Binding var fileEditLoading: Bool
    @Binding var fileEditSaving: Bool
    let onLoadFileEdit: (PendingSFTPFileEdit) async -> Void
    let onSaveFileEdit: () async -> Void

    func body(content: Content) -> some View {
        content
            .alert("重命名", isPresented: Binding(
                get: { pendingRename != nil },
                set: { if !$0 { pendingRename = nil } }
            )) {
                TextField("新名称", text: $renameText)
                Button("取消", role: .cancel) {
                    pendingRename = nil
                }
                Button("确认") {
                    guard let rename = pendingRename,
                          let session = sessionManager.session(for: rename.sessionID) else {
                        pendingRename = nil
                        return
                    }
                    let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    pendingRename = nil
                    Task { await session.sftpManager.rename(item: rename.item, to: newName) }
                }
            } message: {
                Text("请输入新的文件名")
            }
            .alert("新建项目", isPresented: Binding(
                get: { pendingCreate != nil },
                set: { if !$0 { pendingCreate = nil } }
            )) {
                TextField("名称", text: $createText)
                Button("取消", role: .cancel) { pendingCreate = nil }
                Button("创建") {
                    guard let create = pendingCreate,
                          let target = sessionManager.session(for: create.sessionID) else {
                        pendingCreate = nil
                        return
                    }
                    let name = createText.trimmingCharacters(in: .whitespacesAndNewlines)
                    pendingCreate = nil
                    Task {
                        if create.kind == .directory {
                            await target.sftpManager.createDirectory(named: name)
                        } else {
                            await target.sftpManager.createFile(named: name)
                        }
                    }
                }
            } message: {
                Text("将在当前目录创建\(pendingCreate?.kind == .directory ? "目录" : "文件")")
            }
            .alert("修改权限", isPresented: Binding(
                get: { pendingChmod != nil },
                set: { if !$0 { pendingChmod = nil } }
            )) {
                TextField("八进制权限（例如 644 / 755）", text: $chmodText)
                Button("取消", role: .cancel) { pendingChmod = nil }
                Button("应用") {
                    guard let chmod = pendingChmod,
                          let target = sessionManager.session(for: chmod.sessionID) else {
                        pendingChmod = nil
                        return
                    }
                    let mode = chmodText.trimmingCharacters(in: .whitespacesAndNewlines)
                    pendingChmod = nil
                    Task { await target.sftpManager.chmod(item: chmod.item, modeOctal: mode) }
                }
            } message: {
                Text("请输入 3-4 位八进制权限")
            }
            .sheet(item: $pendingFileEdit) { edit in
                NavigationStack {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(edit.item.name)
                                .font(.headline)
                                .lineLimit(1)
                            Spacer()
                            if fileEditLoading || fileEditSaving {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        if !fileEditStatus.isEmpty {
                            Text(fileEditStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        TextEditor(text: $fileEditContent)
                            .font(.system(.body, design: .monospaced))
                            .padding(6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        HStack {
                            Button("关闭") {
                                pendingFileEdit = nil
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            Button("保存") {
                                Task { await onSaveFileEdit() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(fileEditLoading || fileEditSaving)
                        }
                    }
                    .padding(14)
                    .navigationTitle("在线编辑")
                    .task(id: edit.id) {
                        await onLoadFileEdit(edit)
                    }
                }
#if os(macOS)
                .frame(minWidth: 700, minHeight: 520)
#endif
            }
    }
}
