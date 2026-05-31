import SwiftUI
import UniformTypeIdentifiers

struct AssetManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession

    @ObservedObject var store: ServerStore
    let onEdit: (ServerEntry) -> Void
    let onConnect: (ServerEntry) -> Void

    @State private var query = ""
    @State private var noticeText: String = ""
    @State private var noticeColor: Color = .secondary
    @State private var policyChangingID: UUID?
    @State private var keySetupServer: ServerEntry?
    @State private var showingBulkAdd = false

    private let vault = CredentialVault.shared
    @StateObject private var orbitManager = OrbitManager()
    @StateObject private var syncService = SyncService.shared

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
                                        deleteServer(server)
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
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingBulkAdd = true
                    } label: {
                        Label("批量添加", systemImage: "square.stack.3d.up.fill")
                    }
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
        .sheet(isPresented: $showingBulkAdd) {
            BulkAddAssetsSheet(store: store) { count in
                noticeColor = count > 0 ? .green : .orange
                noticeText = count > 0 ? "已批量添加 \(count) 个资产，并已进入后台同步" : "未添加资产，请检查输入格式"
            }
            .environmentObject(session)
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
        syncServerUpdate(updated)
        noticeColor = .green
        noticeText = "已开启密码登录：\(server.name)"
    }

    private func deleteServer(_ server: ServerEntry) {
        store.remove(server)
        let token = session.readToken()
        let masterPassword = session.readMasterPassword()
        Task(priority: .background) {
            await syncService.deleteRemoteConfigs(for: [server], token: token, masterPassword: masterPassword)
        }
    }

    private func syncServerUpdate(_ server: ServerEntry) {
        guard let credentials = try? vault.read(for: server.credentialID),
              let token = session.readToken(),
              let masterPassword = session.readMasterPassword() else { return }
        let portable = server.makePortableConfig(savedAtUnix: Int(Date().timeIntervalSince1970), credentials: credentials)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(portable),
              let plain = String(data: data, encoding: .utf8) else { return }
        Task(priority: .background) {
            _ = await syncService.uploadEncryptedConfig(
                token: token,
                masterPassword: masterPassword,
                plaintextConfig: plain,
                vectorClock: ["client": Int(Date().timeIntervalSince1970)],
                allowQueueOnNetworkFailure: true
            )
        }
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
        syncServerUpdate(updated)
        noticeColor = .green
        noticeText = "已关闭密码登录（仅密钥模式）：\(server.name)"
    }
}

private struct BulkAddAssetsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession

    @ObservedObject var store: ServerStore
    let onFinish: (Int) -> Void

    @StateObject private var syncService = SyncService.shared
    @State private var rawText = """
    名称,分组,主机,端口,用户名,密码,协议,认证方式,私钥内容
    Web-01,生产,192.168.1.10,22,root,change-me,ssh,password,
    Switch-01,网络,192.168.1.20,23,admin,change-me,telnet,password,
    """
    @State private var statusText = "支持逗号、Tab 或分号分隔。一行一个资产。"
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("字段顺序：名称、分组、主机、端口、用户名、密码、协议、认证方式、私钥内容")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $rawText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 260)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack {
                    Button("取消") { dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("导入并同步") {
                        Task { await importAssets() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }
            }
            .padding(16)
            .navigationTitle("批量添加资产")
        }
#if os(macOS)
        .frame(minWidth: 760, minHeight: 520)
#endif
    }

    @MainActor
    private func importAssets() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let parsed = parseRows(rawText)
        guard !parsed.isEmpty else {
            statusText = "没有解析到有效资产"
            onFinish(0)
            return
        }

        for item in parsed {
            store.addOrUpdate(item.server, credentials: item.credentials)
        }

        statusText = "已保存 \(parsed.count) 个资产，正在后台同步..."
        await syncImported(parsed)
        onFinish(parsed.count)
        dismiss()
    }

    private func parseRows(_ text: String) -> [(server: ServerEntry, credentials: ServerCredentials)] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> (ServerEntry, ServerCredentials)? in
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

                let fields = splitRow(line)
                guard fields.count >= 5 else { return nil }
                if fields[0].localizedCaseInsensitiveContains("名称") ||
                    fields[0].localizedCaseInsensitiveContains("name") {
                    return nil
                }

                let name = fields[safe: 0].trimmed
                let group = fields[safe: 1].trimmed
                let host = fields[safe: 2].trimmed
                let port = Int(fields[safe: 3].trimmed) ?? 22
                let username = fields[safe: 4].trimmed
                let password = fields[safe: 5].trimmed
                let transportRaw = fields[safe: 6].trimmed.lowercased()
                let authRaw = fields[safe: 7].trimmed.lowercased()
                let keyContent = fields.dropFirst(8).joined(separator: ",").trimmingCharacters(in: .whitespacesAndNewlines)

                guard !host.isEmpty, !username.isEmpty else { return nil }
                let transport: ServerTransportProtocol = transportRaw == "telnet" ? .telnet : .ssh
                let authMethod: ServerAuthMethod = authRaw == "key" || !keyContent.isEmpty ? .key : .password
                let server = ServerEntry(
                    name: name.isEmpty ? host : name,
                    group: group,
                    host: host,
                    port: max(1, min(65535, port)),
                    username: username,
                    authMethod: authMethod,
                    transport: transport,
                    allowPasswordFallback: !password.isEmpty
                )
                let credentials = ServerCredentials(password: password, privateKeyContent: keyContent)
                return (server, credentials)
            }
    }

    private func splitRow(_ line: String) -> [String] {
        if line.contains("\t") {
            return line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
        if line.contains(";") && !line.contains(",") {
            return line.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        }
        return line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    private func syncImported(_ items: [(server: ServerEntry, credentials: ServerCredentials)]) async {
        guard let token = session.readToken(),
              let masterPassword = session.readMasterPassword() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for item in items {
            let portable = item.server.makePortableConfig(
                savedAtUnix: Int(Date().timeIntervalSince1970),
                credentials: item.credentials
            )
            guard let data = try? encoder.encode(portable),
                  let plain = String(data: data, encoding: .utf8) else { continue }
            _ = await syncService.uploadEncryptedConfig(
                token: token,
                masterPassword: masterPassword,
                plaintextConfig: plain,
                vectorClock: ["client": Int(Date().timeIntervalSince1970)],
                allowQueueOnNetworkFailure: true
            )
        }
    }
}

private extension Array where Element == String {
    subscript(safe index: Int) -> String {
        indices.contains(index) ? self[index] : ""
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
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
    @EnvironmentObject private var session: AppSession

    let server: ServerEntry
    @ObservedObject var store: ServerStore
    let onFinish: (QuickKeySetupResult) -> Void

    @StateObject private var orbitManager = OrbitManager()
    @StateObject private var syncService = SyncService.shared

    @State private var keyInputMode: AssetKeyInputMode = .paste
    @State private var privateKeyContent = ""
    @State private var privateKeyPassphrase = ""
    @State private var selectedKeyFileName = ""
    @State private var showKeyFileImporter = false
    @State private var isTesting = false
    @State private var isDeploying = false
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
                    if isTesting || isDeploying || saving {
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
#if os(macOS)
                    Button("生成并部署密钥") {
                        Task { await generateAndDeployKey() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTesting || isDeploying || saving)
#endif
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

#if os(macOS)
    @MainActor
    private func generateAndDeployKey() async {
        guard !isDeploying else { return }
        guard let old = try? vault.read(for: server.credentialID),
              !old.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusText = "生成部署失败：需要先保存密码凭据，才能把公钥写入远端"
            statusColor = .orange
            return
        }

        isDeploying = true
        keyVerified = false
        statusText = "正在生成本地 Ed25519 密钥..."
        statusColor = .secondary
        defer { isDeploying = false }

        do {
            let pair = try await generateEd25519KeyPair(passphrase: privateKeyPassphrase)
            privateKeyContent = pair.privateKey
            statusText = "正在部署公钥到远端 authorized_keys..."

            let deployCommand = authorizedKeysCommand(publicKey: pair.publicKey)
            _ = try await orbitManager.executeRemoteCommandAsync(
                ip: server.host,
                port: server.port,
                username: server.username,
                password: old.password,
                privateKeyContent: "",
                privateKeyPassphrase: "",
                allowPasswordFallback: true,
                command: deployCommand
            )

            let result = await orbitManager.testConnectionAsync(
                ip: server.host,
                port: server.port,
                username: server.username,
                password: "",
                privateKeyContent: pair.privateKey,
                privateKeyPassphrase: privateKeyPassphrase,
                allowPasswordFallback: false
            )

            guard result.hasPrefix("成功") else {
                statusText = "公钥已写入，但密钥测试失败：\(result)"
                statusColor = .orange
                return
            }

            keyVerified = true
            statusText = "密钥已生成、部署并测试成功，可选择关闭密码登录"
            statusColor = .green
        } catch {
            statusText = "生成部署失败：\(error.localizedDescription)"
            statusColor = .red
        }
    }

    private func generateEd25519KeyPair(passphrase: String) async throws -> (privateKey: String, publicKey: String) {
        try await Task.detached(priority: .userInitiated) {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("orbitterm-key-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let keyURL = dir.appendingPathComponent("id_ed25519")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = [
                "-t", "ed25519",
                "-a", "64",
                "-N", passphrase,
                "-C", "orbitterm-\(server.id.uuidString)",
                "-f", keyURL.path
            ]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let err = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ssh-keygen 执行失败"
                throw OrbitManagerError.rustError(err.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            let privateKey = try String(contentsOf: keyURL, encoding: .utf8)
            let publicKey = try String(contentsOf: keyURL.appendingPathExtension("pub"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (privateKey, publicKey)
        }.value
    }

    private func authorizedKeysCommand(publicKey: String) -> String {
        let quoted = shellSingleQuote(publicKey)
        return """
        umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && grep -qxF \(quoted) ~/.ssh/authorized_keys || printf '%s\\n' \(quoted) >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys
        """
    }

    private func shellSingleQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
#endif

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
            await syncServerUpdate(updatedServer, credentials: updatedCreds)

            onFinish(.saved(closePasswordLogin ? "密钥已保存并切换为仅密钥登录" : "密钥已保存"))
            dismiss()
        } catch {
            statusText = "保存失败: \(error.localizedDescription)"
            statusColor = .red
            onFinish(.failed(statusText))
        }
    }

    private func syncServerUpdate(_ server: ServerEntry, credentials: ServerCredentials) async {
        guard let token = session.readToken(),
              let masterPassword = session.readMasterPassword() else { return }
        let portable = server.makePortableConfig(savedAtUnix: Int(Date().timeIntervalSince1970), credentials: credentials)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(portable),
              let plain = String(data: data, encoding: .utf8) else { return }
        _ = await syncService.uploadEncryptedConfig(
            token: token,
            masterPassword: masterPassword,
            plaintextConfig: plain,
            vectorClock: ["client": Int(Date().timeIntervalSince1970)],
            allowQueueOnNetworkFailure: true
        )
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
