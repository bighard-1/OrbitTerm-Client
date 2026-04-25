import SwiftUI
import UniformTypeIdentifiers

struct AssetManagerView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var store: ServerStore
    let onEdit: (ServerEntry) -> Void
    let onConnect: (ServerEntry) -> Void

    @State private var query = ""
    @State private var noticeText: String = ""
    @State private var noticeColor: Color = .secondary
    @State private var policyChangingID: UUID?
    @State private var keySetupServer: ServerEntry?

    private let vault = CredentialVault.shared
    @StateObject private var orbitManager = OrbitManager()

    var body: some View {
        NavigationStack {
            List {
                if filteredServers.isEmpty {
                    ContentUnavailableView(
                        "暂无匹配资产",
                        systemImage: "server.rack",
                        description: Text(query.isEmpty ? "还没有已保存服务器" : "尝试更换搜索关键词")
                    )
                } else {
                    ForEach(groupedFiltered, id: \.group) { section in
                        Section(section.group) {
                            ForEach(section.items) { server in
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(store.selectedServerID == server.id ? Color.green : Color.gray.opacity(0.35))
                                        .frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(server.name)
                                            .font(.body.weight(.medium))
                                        Text("\(server.username)@\(server.host):\(server.port)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("连接") { onConnect(server) }
                                        .buttonStyle(.borderedProminent)
                                    Button("编辑") { onEdit(server) }
                                        .buttonStyle(.bordered)
                                    Button("设密钥") { keySetupServer = server }
                                        .buttonStyle(.bordered)
                                }
                                .contextMenu {
                                    Button("连接") { onConnect(server) }
                                    Button("编辑凭据") { onEdit(server) }
                                    Button("一键设置密钥") { keySetupServer = server }
                                    if server.allowPasswordFallback {
                                        Button("关闭密码登录") {
                                            Task { await disablePasswordFallback(server) }
                                        }
                                    } else {
                                        Button("开启密码登录") {
                                            enablePasswordFallback(server)
                                        }
                                    }
                                    Button("删除", role: .destructive) {
                                        store.remove(server)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "搜索名称 / 主机 / 用户名")
            .navigationTitle("资产管理")
            .safeAreaInset(edge: .bottom) {
                if !noticeText.isEmpty {
                    HStack(spacing: 8) {
                        if let changingID = policyChangingID,
                           filteredServers.contains(where: { $0.id == changingID }) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "info.circle.fill")
                        }
                        Text(noticeText)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .foregroundStyle(noticeColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .sheet(item: $keySetupServer) { server in
            QuickKeySetupSheet(server: server, store: store) { status in
                switch status {
                case let .saved(message):
                    noticeColor = .green
                    noticeText = message
                case let .failed(message):
                    noticeColor = .orange
                    noticeText = message
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 760, minHeight: 520)
#endif
    }

    private var filteredServers: [ServerEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.servers }
        return store.servers.filter { server in
            server.name.localizedCaseInsensitiveContains(q) ||
                server.host.localizedCaseInsensitiveContains(q) ||
                server.username.localizedCaseInsensitiveContains(q) ||
                server.group.localizedCaseInsensitiveContains(q)
        }
    }

    private var groupedFiltered: [(group: String, items: [ServerEntry])] {
        let grouped = Dictionary(grouping: filteredServers, by: { $0.displayGroup })
        return grouped.keys.sorted().map { key in
            (group: key, items: (grouped[key] ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
    }

    private func enablePasswordFallback(_ server: ServerEntry) {
        var updated = server
        updated.allowPasswordFallback = true
        store.addOrUpdate(updated)
        noticeColor = .green
        noticeText = "已开启密码登录：\(server.name)"
    }

    private func disablePasswordFallback(_ server: ServerEntry) async {
        guard policyChangingID == nil else { return }
        policyChangingID = server.id
        defer { policyChangingID = nil }

        guard let credentials = try? vault.read(for: server.credentialID),
              !credentials.privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            noticeColor = .orange
            noticeText = "关闭失败：请先为 \(server.name) 设置有效私钥并测试通过"
            return
        }

        let result = await orbitManager.testConnectionAsync(
            ip: server.host,
            port: server.port,
            username: server.username,
            password: "",
            privateKeyContent: credentials.privateKeyContent,
            privateKeyPassphrase: credentials.privateKeyPassphrase,
            allowPasswordFallback: false
        )

        guard result.hasPrefix("成功") else {
            noticeColor = .orange
            noticeText = "关闭失败：密钥登录测试未通过（\(result)）"
            return
        }

        var updated = server
        updated.allowPasswordFallback = false
        store.addOrUpdate(updated)
        noticeColor = .green
        noticeText = "已关闭密码登录（仅密钥模式）：\(server.name)"
    }
}

private enum QuickKeySetupResult {
    case saved(String)
    case failed(String)
}

private enum AssetKeyInputMode: String, CaseIterable, Identifiable {
    case paste
    case file

    var id: String { rawValue }
    var title: String {
        switch self {
        case .paste: return "粘贴字符串"
        case .file: return "选择文件"
        }
    }
}

private struct QuickKeySetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    let server: ServerEntry
    @ObservedObject var store: ServerStore
    let onFinish: (QuickKeySetupResult) -> Void

    @StateObject private var orbitManager = OrbitManager()

    @State private var keyInputMode: AssetKeyInputMode = .paste
    @State private var privateKeyContent = ""
    @State private var privateKeyPassphrase = ""
    @State private var selectedKeyFileName = ""
    @State private var showKeyFileImporter = false
    @State private var isTesting = false
    @State private var keyVerified = false
    @State private var saving = false
    @State private var closePasswordLogin = false
    @State private var statusText = "尚未测试密钥连通性"
    @State private var statusColor: Color = .secondary

    private let vault = CredentialVault.shared

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(server.name)
                    .font(.headline)
                Text("\(server.username)@\(server.host):\(server.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("密钥输入方式", selection: $keyInputMode) {
                    ForEach(AssetKeyInputMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if keyInputMode == .file {
                    Button {
                        showKeyFileImporter = true
                    } label: {
                        Label(selectedKeyFileName.isEmpty ? "选择私钥文件" : selectedKeyFileName, systemImage: "doc.badge.plus")
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                }

                TextEditor(text: $privateKeyContent)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 140)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))

                SecureField("私钥口令（可选）", text: $privateKeyPassphrase)
                    .textFieldStyle(.roundedBorder)

                Toggle("关闭密码登录（仅密钥）", isOn: $closePasswordLogin)
                    .onChange(of: closePasswordLogin) { _, isOn in
                        if isOn && !keyVerified {
                            closePasswordLogin = false
                            statusText = "请先完成密钥连接测试并通过，才能关闭密码登录"
                            statusColor = .orange
                        }
                    }

                HStack(spacing: 8) {
                    if isTesting || saving {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }

                Spacer(minLength: 0)

                HStack {
                    Button("取消") { dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("测试密钥") {
                        Task { await testKeyConnection() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTesting || saving || !hasValidKey)

                    Button("保存") {
                        Task { await save() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTesting || saving || !hasValidKey || (closePasswordLogin && !keyVerified))
                }
            }
            .padding(16)
            .navigationTitle("一键设置密钥")
            .background(.ultraThinMaterial)
            .task {
                if let existing = try? vault.read(for: server.credentialID) {
                    privateKeyContent = existing.privateKeyContent
                    privateKeyPassphrase = existing.privateKeyPassphrase
                }
            }
        }
        .fileImporter(
            isPresented: $showKeyFileImporter,
            allowedContentTypes: [.data, .plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            guard keyInputMode == .file else { return }
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                selectedKeyFileName = url.lastPathComponent
                loadPrivateKeyFile(url)
            case let .failure(error):
                statusText = "私钥文件读取失败: \(error.localizedDescription)"
                statusColor = .red
            }
        }
#if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
#endif
    }

    private var hasValidKey: Bool {
        let key = privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        let pattern = #"(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*-----END [A-Z0-9 ]*PRIVATE KEY-----"#
        return key.range(of: pattern, options: .regularExpression) != nil
    }

    private func testKeyConnection() async {
        guard hasValidKey else { return }
        isTesting = true
        defer { isTesting = false }

        let result = await orbitManager.testConnectionAsync(
            ip: server.host,
            port: server.port,
            username: server.username,
            password: "",
            privateKeyContent: privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines),
            privateKeyPassphrase: privateKeyPassphrase,
            allowPasswordFallback: false
        )
        if result.hasPrefix("成功") {
            keyVerified = true
            statusText = "密钥测试成功"
            statusColor = .green
        } else {
            keyVerified = false
            statusText = "密钥测试失败：\(result)"
            statusColor = .red
        }
    }

    private func save() async {
        guard hasValidKey else { return }
        if closePasswordLogin && !keyVerified {
            statusText = "请先通过密钥测试，再关闭密码登录"
            statusColor = .orange
            return
        }

        saving = true
        defer { saving = false }

        do {
            let old = try vault.read(for: server.credentialID) ?? ServerCredentials()
            let updatedCreds = ServerCredentials(
                password: old.password,
                privateKeyContent: privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines),
                privateKeyPassphrase: privateKeyPassphrase
            )
            try vault.save(updatedCreds, for: server.credentialID)

            var updatedServer = server
            if closePasswordLogin {
                updatedServer.allowPasswordFallback = false
            }
            store.addOrUpdate(updatedServer)

            onFinish(.saved(closePasswordLogin ? "密钥已保存并切换为仅密钥登录" : "密钥已保存"))
            dismiss()
        } catch {
            statusText = "保存失败: \(error.localizedDescription)"
            statusColor = .red
            onFinish(.failed(statusText))
        }
    }

    private func loadPrivateKeyFile(_ url: URL) {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try Data(contentsOf: url)
            guard let key = String(data: data, encoding: .utf8) else {
                statusText = "私钥文件不是 UTF-8 文本"
                statusColor = .red
                return
            }
            privateKeyContent = key
            keyVerified = false
            statusText = "私钥已载入，请先测试"
            statusColor = .secondary
        } catch {
            statusText = "私钥文件读取失败: \(error.localizedDescription)"
            statusColor = .red
        }
    }
}
