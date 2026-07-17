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
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(crumbs) { crumb in
                    Button(action: { onSelect(crumb) }) {
                        Text(crumb.title)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(crumb.isLast ? palette.textPrimary.color : palette.accentPrimary.color)

                    if !crumb.isLast {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(palette.textSecondary.color)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(palette.surfaceGlassStrong.color)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.divider.color).frame(height: 1) }
    }
}

struct SFTPSummaryBar: View {
    let itemCount: Int
    let directoryCount: Int
    let fileCount: Int
    let currentPath: String
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Text("总计 \(itemCount)")
            Text("目录 \(directoryCount)")
            Text("文件 \(fileCount)")
            Spacer()
            Text(currentPath)
                .lineLimit(1)
                .foregroundStyle(palette.textSecondary.color)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(palette.textPrimary.color)
        .background(palette.surfaceGlass.color)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.divider.color).frame(height: 1) }
    }
}

struct SFTPFileRow: View {
    let item: FileItem
    let isSelected: Bool
    let onToggleSelection: () -> Void
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleSelection) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? palette.accentPrimary.color : palette.textSecondary.color)
                    .font(.body)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "取消选择 \(item.name)" : "选择 \(item.name)")

            Image(systemName: item.iconName)
                .foregroundStyle(item.isDirectory ? palette.accentPrimary.color : palette.textSecondary.color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .foregroundStyle(palette.textPrimary.color)
                Text("\(item.permissions)  ·  \(item.formattedDate)")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
            }

            Spacer()

            if !item.isDirectory {
                Text(item.formattedSize)
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isSelected ? palette.accentPrimary.color.opacity(0.14) : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(isSelected ? palette.focusRing.color.opacity(0.7) : Color.clear, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name)，\(item.isDirectory ? "目录" : "文件")，\(item.formattedSize)")
    }
}

struct SFTPEmptyFolderView: View {
    @Environment(\.appThemePalette) private var palette
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(palette.accentPrimary.color)
            Text("Empty Folder")
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.textPrimary.color)
            Text("当前目录没有任何文件。可以尝试上传，或者切换到其他路径。")
                .font(.callout)
                .foregroundStyle(palette.textSecondary.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(palette.surfaceGlass.color, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct SFTPBatchToolbar: View {
    let selectedCount: Int
    let progress: BatchDownloadProgress?
    let isRunning: Bool
    let onCancel: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已选中 \(selectedCount) 项")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.textPrimary.color)
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(.bordered)
            }

            if let progress, isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction)
                    Text("下载进度 \(progress.completed)/\(progress.total) · \(FileSizeFormatter.humanReadable(progress.bytesTransferred))")
                        .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
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
        .tint(SFTPTransferSemanticRole.inProgress.themeColor(in: security, fallback: palette).color)
        .background(palette.surfaceGlassStrong.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.borderGlass.color, lineWidth: 1)
        )
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedCount)
    }
}

struct SFTPTransferBoard: View {
    let transfers: [TransferTaskItem]
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security

    var body: some View {
        if !transfers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("传输任务")
                    .font(.headline)
                    .foregroundStyle(palette.textPrimary.color)

                ForEach(transfers.prefix(3)) { task in
                    VStack(alignment: .leading, spacing: 4) {
                        let role = transferRole(for: task)
                        let presentation = security.presentation(for: role.securityKind ?? .information)
                        HStack(spacing: 6) {
                            Image(systemName: presentation.symbol)
                                .foregroundStyle(role.themeColor(in: security, fallback: palette).color)
                            Text("\(task.direction.rawValue): \(task.fileName)")
                                .font(.subheadline)
                                .lineLimit(1)
                                .foregroundStyle(palette.textPrimary.color)
                        }
                        ProgressView(value: task.progress)
                            .tint(role.themeColor(in: security, fallback: palette).color)
                        Text(task.statusText)
                            .font(.caption)
                            .foregroundStyle(role.themeColor(in: security, fallback: palette).color)
                            .accessibilityLabel("\(presentation.label)：\(task.statusText)")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(task.fileName)，\(security.presentation(for: transferRole(for: task).securityKind ?? .information).label)，进度 \(Int(task.progress * 100))%")
                }
            }
            .padding(12)
            .background(palette.surfaceGlassStrong.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(palette.borderGlass.color, lineWidth: 1)
            )
        }
    }

    private func transferRole(for task: TransferTaskItem) -> SFTPTransferSemanticRole {
        SFTPTransferSemanticRole.transferState(isDone: task.isDone, progress: task.progress)
    }
}

#if os(macOS)
struct SFTPRevealInFinderToast: View {
    let revealURL: URL
    let onReveal: () -> Void
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(SFTPTransferSemanticRole.success.themeColor(in: security, fallback: palette).color)
            Text("批量下载完成")
                .font(.caption)
                .foregroundStyle(palette.textPrimary.color)
            Button("在访达中显示", action: onReveal)
                .buttonStyle(.link)
        }
        .padding(10)
        .background(palette.surfaceGlassStrong.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.borderGlass.color, lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }
}
#endif
