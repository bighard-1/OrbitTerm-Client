import SwiftUI
import UniformTypeIdentifiers

struct SFTPBrowserView: View {
    private struct Breadcrumb: Identifiable {
        let id: Int
        let title: String
        let path: String
        let isLast: Bool
    }

    @StateObject private var manager = SFTPManager()

    @State private var host: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var preferMockMode: Bool = false
    @State private var isDropTargeted: Bool = false

    @State private var renameItem: FileItem?
    @State private var newName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            if !manager.isConnected {
                connectPanel
            } else {
                browserPanel
            }
        }
        .navigationTitle("SFTP 浏览器")
        .task {
            manager.activateMockIfNeeded(host: host, username: username, password: password)
        }
    }

    private var connectPanel: some View {
        Form {
            Section("连接信息") {
                TextField("主机或 IP", text: $host)
                    .applyInputPolish()
                TextField("用户名", text: $username)
                    .applyInputPolish()
                SecureField("密码", text: $password)
            }

            Section("模式") {
                Toggle("优先使用模拟数据", isOn: $preferMockMode)
                Text("若未配置 SSH，系统会自动进入 Mock 文件列表。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("操作") {
                Button(preferMockMode ? "进入模拟浏览" : "连接 SFTP") {
                    Task {
                        await manager.connect(
                            host: host,
                            username: username,
                            password: password,
                            preferMock: preferMockMode
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.isLoading)
            }

            if !manager.statusText.isEmpty {
                Section("状态") {
                    Text(manager.statusText)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var browserPanel: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                breadcrumbBar

                if manager.isLoading {
                    ProgressView("加载中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if manager.items.isEmpty {
                    emptyFolderView
                } else {
                    List(manager.items) { item in
                        fileRow(item)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if item.isDirectory {
                                    Task { await manager.enterDirectory(item) }
                                }
                            }
                            .contextMenu {
                                Button("下载") {
                                    Task {
                                        let local = defaultDownloadURL(fileName: item.name)
                                        await manager.download(item: item, to: local)
                                    }
                                }

                                Button("删除", role: .destructive) {
                                    Task { await manager.delete(item: item) }
                                }

                                Button("重命名") {
                                    renameItem = item
                                    newName = item.name
                                }
                            }
                    }
                    .listStyle(.inset)
                    .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                        handleDrop(providers: providers)
                    }
                    .overlay {
                        if isDropTargeted {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(.blue, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                                .padding(8)
                        }
                    }
                }
            }

            transferBoard
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("刷新") {
                    Task { try? await manager.refresh() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("断开") {
                    Task { await manager.disconnect() }
                }
            }
            if manager.isUsingMockData {
                ToolbarItem(placement: .automatic) {
                    Text("MOCK")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.15), in: Capsule())
                }
            }
        }
        .alert("重命名", isPresented: Binding(
            get: { renameItem != nil },
            set: { if !$0 { renameItem = nil } }
        )) {
            TextField("新名称", text: $newName)
            Button("取消", role: .cancel) { renameItem = nil }
            Button("确认") {
                if let renameItem {
                    Task { await manager.rename(item: renameItem, to: newName) }
                }
                self.renameItem = nil
            }
        } message: {
            Text("输入新的文件名")
        }
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pathCrumbs) { crumb in
                    Button(action: {
                        Task { await manager.goToPath(crumb.path) }
                    }) {
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

    private var pathCrumbs: [Breadcrumb] {
        if manager.currentPath == "/" {
            return [Breadcrumb(id: 0, title: "Root", path: "/", isLast: true)]
        }

        let parts = manager.currentPath.split(separator: "/").map(String.init)
        var result: [(String, String)] = [("Root", "/")]
        var runningPath = ""

        for part in parts {
            runningPath += "/\(part)"
            result.append((part, runningPath))
        }
        return result.enumerated().map { index, element in
            Breadcrumb(
                id: index,
                title: element.0,
                path: element.1,
                isLast: index == result.count - 1
            )
        }
    }

    private func fileRow(_ item: FileItem) -> some View {
        HStack(spacing: 12) {
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
    }

    private var emptyFolderView: some View {
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

    @ViewBuilder
    private var transferBoard: some View {
        if !manager.transfers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("传输任务")
                    .font(.headline)

                ForEach(manager.transfers.prefix(3)) { task in
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

    private func defaultDownloadURL(fileName: String) -> URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #endif
        return base.appendingPathComponent(fileName)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let accepted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !accepted.isEmpty else { return false }

        for provider in accepted {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                Task { @MainActor in
                    await manager.upload(localURL: url)
                }
            }
        }

        return true
    }
}
