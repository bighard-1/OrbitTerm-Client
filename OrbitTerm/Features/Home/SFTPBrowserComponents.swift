import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SFTPBreadcrumb: Identifiable {
    let id: Int
    let title: String
    let path: String
    let isLast: Bool
}

struct SFTPBreadcrumbBar: View {
    let crumbs: [SFTPBreadcrumb]
    let onSelect: (SFTPBreadcrumb) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(crumbs) { crumb in
                    Button(action: { onSelect(crumb) }) {
                        Text(crumb.title)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(crumb.isLast ? Color.primary : Color.blue)

                    if !crumb.isLast {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }
}

struct SFTPSummaryBar: View {
    let itemCount: Int
    let directoryCount: Int
    let fileCount: Int
    let currentPath: String

    var body: some View {
        HStack(spacing: 12) {
            Text("总计 \(itemCount)")
            Text("目录 \(directoryCount)")
            Text("文件 \(fileCount)")
            Spacer()
            Text(currentPath)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }
}

struct SFTPFileRow: View {
    let item: FileItem
    let isSelected: Bool
    let onToggleSelection: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleSelection) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.body)
            }
            .buttonStyle(.plain)

            Image(systemName: item.iconName)
                .foregroundStyle(item.isDirectory ? .blue : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                Text("\(item.permissions)  ·  \(item.formattedDate)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !item.isDirectory {
                Text(item.formattedSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SFTPEmptyFolderView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Empty Folder")
                .font(.title3.weight(.semibold))
            Text("当前目录没有任何文件。可以尝试上传，或者切换到其他路径。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(
            LinearGradient(
                colors: [Color.blue.opacity(0.05), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

struct SFTPBatchToolbar: View {
    let selectedCount: Int
    let progress: BatchDownloadProgress?
    let isRunning: Bool
    let onCancel: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已选中 \(selectedCount) 项")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(.bordered)
            }

            if let progress, isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction)
                    Text("下载进度 \(progress.completed)/\(progress.total) · \(FileSizeFormatter.humanReadable(progress.bytesTransferred))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button("下载", action: onDownload)
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning)

                Button("删除", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
                    .disabled(isRunning)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: selectedCount)
    }
}

struct SFTPTransferBoard: View {
    let transfers: [TransferTaskItem]

    var body: some View {
        if !transfers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("传输任务")
                    .font(.headline)

                ForEach(transfers.prefix(3)) { task in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(task.direction.rawValue): \(task.fileName)")
                            .font(.subheadline)
                            .lineLimit(1)
                        ProgressView(value: task.progress)
                        Text(task.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
    }
}

#if os(macOS)
struct SFTPRevealInFinderToast: View {
    let revealURL: URL
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("批量下载完成")
                .font(.caption)
            Button("在访达中显示", action: onReveal)
                .buttonStyle(.link)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }
}
#endif
