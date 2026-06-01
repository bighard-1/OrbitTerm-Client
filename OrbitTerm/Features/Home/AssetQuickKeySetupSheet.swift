import SwiftUI
import UniformTypeIdentifiers

enum QuickKeySetupResult {
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

struct QuickKeySetupSheet: View {
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
