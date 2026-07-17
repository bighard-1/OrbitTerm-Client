import SwiftUI

struct WorkstationSFTPCardView: View {
    let active: WorkspaceSession
    let onRefresh: () -> Void
    let onCreateDirectory: () -> Void
    let onCreateFile: () -> Void
    let onUp: () -> Void
    let onEnterDirectory: (FileItem) -> Void
    let onOpenFile: (FileItem) -> Void
    let onDownload: (FileItem) -> Void
    let onRename: (FileItem) -> Void
    let onChmod: (FileItem) -> Void
    let onSetMode: (FileItem, String) -> Void
    let onDelete: (FileItem) -> Void
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            Text(active.sftpManager.statusText)
                .font(.caption)
                .foregroundStyle(palette.textSecondary.color)

            HStack(spacing: 10) {
                Text("总计 \(active.sftpManager.items.count)")
                Text("目录 \(active.sftpManager.items.filter { $0.isDirectory }.count)")
                Text("文件 \(active.sftpManager.items.filter { !$0.isDirectory }.count)")
            }
            .font(.caption2)
            .foregroundStyle(palette.textSecondary.color)

            if active.sftpManager.items.isEmpty {
                Text("连接后自动展示远程文件")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
            } else {
                ForEach(active.sftpManager.items) { item in
                    fileRow(item)
                }
            }
        }
        .padding(10)
        .foregroundStyle(palette.textPrimary.color)
        .background(palette.surfaceGlassStrong.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.borderGlass.color, lineWidth: 1))
    }

    private var header: some View {
        HStack {
            Text("SFTP")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button("刷新", action: onRefresh)
                .buttonStyle(.bordered)
            Button("新建目录", action: onCreateDirectory)
                .buttonStyle(.bordered)
            Button("新建文件", action: onCreateFile)
                .buttonStyle(.bordered)
            Button("上级", action: onUp)
                .buttonStyle(.bordered)
        }
    }

    private func fileRow(_ item: FileItem) -> some View {
        HStack {
            Image(systemName: item.iconName)
                .foregroundStyle(item.isDirectory ? palette.accentPrimary.color : palette.textSecondary.color)
            Text(item.name)
                .lineLimit(1)
            Spacer()
            Text(item.formattedSize)
                .font(.caption2)
                .foregroundStyle(palette.textSecondary.color)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard item.isDirectory else { return }
            onEnterDirectory(item)
        }
        .onTapGesture(count: 2) {
            guard !item.isDirectory else { return }
            onOpenFile(item)
        }
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
        }
    }
}
