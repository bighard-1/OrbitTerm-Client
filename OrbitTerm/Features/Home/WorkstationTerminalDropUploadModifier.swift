import SwiftUI
import UniformTypeIdentifiers

private struct TerminalDropToast: Identifiable {
    let id = UUID()
    let message: String
    let progress: Double?
    let isError: Bool
}

struct WorkstationTerminalDropUploadModifier: ViewModifier {
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var sessionManager: SessionManager
    @State private var isDropTargeted = false
    @State private var uploadToast: TerminalDropToast?

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Color.blue.opacity(0.72) : Color.secondary.opacity(0.12),
                        style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: isDropTargeted ? [7, 5] : [])
                    )
            )
            .overlay(alignment: .bottomTrailing) {
                if let toast = uploadToast {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "arrow.up.circle.fill")
                                .foregroundStyle(toast.isError ? .orange : .blue)
                            Text(toast.message)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        if let progress = toast.progress {
                            ProgressView(value: progress)
                                .frame(width: 180)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
                    )
                    .padding(10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isDropTargeted)
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleTerminalDrop(providers: providers)
            }
    }

    private func handleTerminalDrop(providers: [NSItemProvider]) -> Bool {
        guard session.isConnected, session.sftpManager.isConnected, !session.sftpManager.isUsingMockData else {
            return false
        }
        let accepted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !accepted.isEmpty else { return false }

        for provider in accepted {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = resolveDropURL(item: item) else { return }
                Task { @MainActor in
                    await uploadDroppedFile(url)
                }
            }
        }
        return true
    }

    private func resolveDropURL(item: NSSecureCoding?) -> URL? {
        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
            return url
        }
        if let url = item as? URL {
            return url
        }
        if let str = item as? String, let url = URL(string: str), url.isFileURL {
            return url
        }
        return nil
    }

    @MainActor
    private func uploadDroppedFile(_ localURL: URL) async {
        guard session.isConnected, session.sftpManager.isConnected, !session.sftpManager.isUsingMockData else {
            return
        }

        let remotePath = remoteUploadPath(fileName: localURL.lastPathComponent)
        withAnimation(.easeInOut(duration: 0.18)) {
            uploadToast = TerminalDropToast(message: "正在上传 \(localURL.lastPathComponent)", progress: 0, isError: false)
        }

        await session.sftpManager.upload(localURL: localURL, remotePath: remotePath) { progress in
            Task { @MainActor in
                uploadToast = TerminalDropToast(message: "正在上传 \(localURL.lastPathComponent)", progress: progress, isError: false)
            }
        }

        let latestTask = session.sftpManager.transfers.first(where: {
            $0.fileName == localURL.lastPathComponent && $0.direction == .upload
        })
        let failed = latestTask?.statusText.contains("失败") ?? false

        if failed {
            withAnimation(.easeInOut(duration: 0.18)) {
                uploadToast = TerminalDropToast(message: latestTask?.statusText ?? "上传失败", progress: 1, isError: true)
            }
            dismissUploadToastLater()
            return
        }

        let pathLiteral = shellPathLiteral(remotePath)
        await sessionManager.sendTerminalBytes(session: session, bytes: Array(pathLiteral.utf8))
        withAnimation(.easeInOut(duration: 0.18)) {
            uploadToast = TerminalDropToast(message: "上传完成，已写入路径", progress: 1, isError: false)
        }
        dismissUploadToastLater()
    }

    private func remoteUploadPath(fileName: String) -> String {
        let current = session.sftpManager.currentPath
        if current == "/" { return "/\(fileName)" }
        return "\(current)/\(fileName)"
    }

    private func shellPathLiteral(_ path: String) -> String {
        if path.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
           !path.contains("'"),
           !path.contains("\"") {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func dismissUploadToastLater() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                uploadToast = nil
            }
        }
    }
}
