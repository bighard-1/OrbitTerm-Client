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

/// Shared path control for the workstation and full SFTP browser. It accepts
/// a remote path only; the SFTP manager performs validation and navigation.
struct SFTPPathNavigator: View {
    @Binding var path: String
    let isEnabled: Bool
    var focusRequest: Int = 0
    let onNavigate: () -> Void
    @Environment(\.appThemePalette) private var palette
    @FocusState private var isPathFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.right.circle")
                .foregroundStyle(palette.textSecondary.color)
                .accessibilityHidden(true)
            TextField("路径直达：/var/log 或 /var/log/syslog", text: $path)
                .textFieldStyle(.plain)
                .font(.caption)
                .focused($isPathFocused)
                .onSubmit(onNavigate)
                .accessibilityLabel("远程路径直达")
                .accessibilityHint("输入目录或文件的远程路径后跳转")
            Button(action: onNavigate) {
                Image(systemName: "arrow.right")
            }
            .buttonStyle(.borderless)
            .disabled(!isEnabled || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("跳转到远程路径")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(palette.surfaceInput.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.borderGlass.color, lineWidth: 1)
        }
        .task(id: focusRequest) {
            guard focusRequest > 0 else { return }
            isPathFocused = true
        }
    }
}

struct SFTPSummaryBar: View {
    let itemCount: Int
    let directoryCount: Int
    let fileCount: Int
    let currentPath: String
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("总计 \(itemCount)")
                Text("目录 \(directoryCount)")
                Text("文件 \(fileCount)")
                Spacer(minLength: 0)
            }
            Text(currentPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
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
    let isPathTarget: Bool
    let onToggleSelection: () -> Void
    @Environment(\.appThemePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggleSelection) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? palette.accentPrimary.color : palette.textSecondary.color)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 28, height: 28)
                    .clipped()
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 44, alignment: .top)
            .clipped()
            .accessibilityLabel(isSelected ? "取消选择 \(item.name)" : "选择 \(item.name)")

            Image(systemName: item.iconName)
                .foregroundStyle(item.isDirectory ? palette.accentPrimary.color : palette.textSecondary.color)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 24, height: 28, alignment: .center)
                .clipped()
                .padding(.top, dynamicTypeSize.isAccessibilitySize ? 3 : 0)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(dynamicTypeSize.isAccessibilitySize ? .tail : .middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(palette.textPrimary.color)
                Text("\(item.permissions)  ·  \(item.formattedDate)")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            if !item.isDirectory {
                Text(item.formattedSize)
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 64 : 44, alignment: .leading)
        .background((isSelected || isPathTarget) ? palette.accentPrimary.color.opacity(0.14) : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke((isSelected || isPathTarget) ? palette.focusRing.color.opacity(0.7) : Color.clear, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name)，\(item.isDirectory ? "目录" : "文件，\(item.formattedSize)")\(isPathTarget ? "，路径直达结果" : "")")
    }
}

struct SFTPEmptyFolderView: View {
    @Environment(\.appThemePalette) private var palette
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(palette.accentPrimary.color)
            Text("此目录为空")
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.textPrimary.color)
            Text("可在此目录新建文件、目录或上传文件。")
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
    private enum QueueSection: String, CaseIterable, Identifiable {
        case active = "进行中"
        case completed = "已完成"
        var id: String { rawValue }
    }

    @ObservedObject var manager: SFTPManager
    @State private var section: QueueSection = .active
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security

    var body: some View {
        if !manager.transfers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(QueueSection.allCases) { item in
                        if item == section {
                            queueButton(item)
                                .buttonStyle(ThemedPrimaryButtonStyle())
                        } else {
                            queueButton(item)
                                .buttonStyle(ThemedSecondaryButtonStyle())
                        }
                    }
                }

                if visibleTransfers.isEmpty {
                    Text(section == .active ? "暂无进行中的传输" : "暂无已完成的传输")
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary.color)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 10)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(visibleTransfers) { task in
                                transferRow(task)
                            }
                        }
                    }
                    .frame(maxHeight: 230)
                }

                if section == .completed {
                    HStack {
                        Spacer()
                        Button("清理已完成") { manager.clearCompletedTransfers() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(visibleTransfers.isEmpty)
                    }
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

    private var visibleTransfers: [TransferTaskItem] {
        switch section {
        case .active:
            manager.transfers.filter { !$0.isDone }
        case .completed:
            manager.transfers.filter(\.isDone)
        }
    }

    private func count(for section: QueueSection) -> Int {
        switch section {
        case .active: manager.transfers.filter { !$0.isDone }.count
        case .completed: manager.transfers.filter(\.isDone).count
        }
    }

    private func queueButton(_ item: QueueSection) -> some View {
        Button {
            section = item
        } label: {
            Text("\(item.rawValue) \(count(for: item))")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
    }

    private func transferRow(_ task: TransferTaskItem) -> some View {
        let role = transferRole(for: task)
        let presentation = security.presentation(for: role.securityKind ?? .information)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: presentation.symbol)
                    .foregroundStyle(role.themeColor(in: security, fallback: palette).color)
                Text("\(task.direction.rawValue): \(task.fileName)")
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(palette.textPrimary.color)
                Spacer(minLength: 4)
                if task.hasFailed {
                    Button("重试") { manager.retryTransfer(task.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }
            ProgressView(value: task.progress)
                .tint(role.themeColor(in: security, fallback: palette).color)
            Text(task.statusText)
                .font(.caption)
                .foregroundStyle(role.themeColor(in: security, fallback: palette).color)
                .accessibilityLabel("\(presentation.label)：\(task.statusText)")
        }
        .padding(8)
        .background(palette.surfaceInput.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.fileName)，\(presentation.label)，进度 \(Int(task.progress * 100))%")
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
