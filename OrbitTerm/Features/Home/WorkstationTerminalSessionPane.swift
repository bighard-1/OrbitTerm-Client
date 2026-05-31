import SwiftUI
import UniformTypeIdentifiers

private struct TerminalDropToast: Identifiable {
    let id = UUID()
    let message: String
    let progress: Double?
    let isError: Bool
}

struct TerminalSessionPane: View {
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var sessionManager: SessionManager
    @Binding var isStressRunning: Bool
    let onSplitStateChanged: (Bool) -> Void
    let onToggleStress: (WorkspaceSession) -> Void
    @State private var isDropTargeted = false
    @State private var uploadToast: TerminalDropToast?
    @State private var showSearchOverlay = false
    @State private var searchText = ""
    @State private var searchCommand: TerminalSearchCommand?
    @State private var searchStatusText = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("终端会话")
                    .font(.headline)
                Spacer()
#if os(macOS)
                Button("分屏 +") {
                    Task { @MainActor in
                        session.terminalSplitCount = min(3, session.terminalSplitCount + 1)
                        onSplitStateChanged(session.terminalSplitCount > 0)
                        await sessionManager.ensureTerminalSplitChannels(session: session)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(session.terminalSplitCount >= 3)

                Button("合并 -") {
                    Task { @MainActor in
                        session.terminalSplitCount = max(0, session.terminalSplitCount - 1)
                        onSplitStateChanged(session.terminalSplitCount > 0)
                        await sessionManager.ensureTerminalSplitChannels(session: session)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(session.terminalSplitCount <= 0)
#endif

                Button("测试连接") {
                    Task { await sessionManager.testConnection(session: session) }
                }

                Button("连接") {
                    Task { await sessionManager.connect(session: session) }
                }
                .buttonStyle(.borderedProminent)

                Button("Ctrl+C") {
                    Task { await sessionManager.sendCtrlC(session: session) }
                }
                .buttonStyle(.bordered)

                Button(isStressRunning ? "停止压测" : "yes 压测") {
                    onToggleStress(session)
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(session.server.name)
                    .font(.title3.weight(.semibold))
                Text("\(session.server.username)@\(session.server.endpointText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if showSearchOverlay {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索终端历史", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSearchFocused)
                        .onSubmit { triggerSearch(.next) }

                    Button {
                        triggerSearch(.previous)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        triggerSearch(.next)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        searchText = ""
                        triggerSearch(.clear)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.bordered)

                    Button("关闭") {
                        showSearchOverlay = false
                        searchStatusText = ""
                    }
                    .buttonStyle(.bordered)
                }

                if !searchStatusText.isEmpty {
                    Text(searchStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            WorkstationTerminalSplitLayoutView(
                session: session,
                sessionManager: sessionManager,
                searchText: searchText,
                searchCommand: searchCommand,
                onSearchFeedback: { found, action in
                    switch action {
                    case .clear:
                        searchStatusText = "已清除搜索高亮"
                    case .next, .previous:
                        searchStatusText = found ? "已定位匹配项" : "未找到匹配项"
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            .onAppear {
                Task {
                    onSplitStateChanged(session.terminalSplitCount > 0)
                    await sessionManager.ensureTerminalSplitChannels(session: session)
                    await sessionManager.resizeTerminal(session: session, cols: 120, rows: 36)
                }
            }
            .overlay(alignment: .topLeading) {
#if os(macOS)
                Button("") {
                    showSearchOverlay = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isSearchFocused = true
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0.001)
                .frame(width: 1, height: 1)
#endif
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleTerminalDrop(providers: providers)
            }

            Text("状态：\(session.terminalStatus)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func triggerSearch(_ action: TerminalSearchAction) {
        searchCommand = TerminalSearchCommand(action: action)
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
