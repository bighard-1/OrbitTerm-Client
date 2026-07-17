import SwiftUI
import UniformTypeIdentifiers

enum QuickKeySetupResult {
    case saved(String)
    case failed(String)
}

struct QuickKeySetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security

    let server: ServerEntry
    @ObservedObject var store: ServerStore
    let onFinish: (QuickKeySetupResult) -> Void

    @StateObject private var orbitManager = OrbitManager()
    @StateObject private var syncService = SyncService.shared

    @State private var keyInputMode: KeyInputMode = .paste
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
    @State private var statusKind: SecurityStatusKind? = nil

    private let vault = CredentialVault.shared

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(server.name)
                    .font(.headline)
                    .foregroundStyle(palette.textPrimary.color)
                Text("\(server.username)@\(server.host):\(server.port)")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)

                Picker("密钥输入方式", selection: $keyInputMode) {
                    ForEach(KeyInputMode.allCases) { mode in
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
                    .buttonStyle(ThemedSecondaryButtonStyle())
                }

                TextEditor(text: $privateKeyContent)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 140)
                    .padding(8)
                    .foregroundStyle(palette.textPrimary.color)
                    .background(palette.surfaceInput.color, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.borderGlass.color))

                SecureField("私钥口令（可选）", text: $privateKeyPassphrase)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .foregroundStyle(palette.textPrimary.color)
                    .themedInputSurface()

                Toggle("关闭密码登录（仅密钥）", isOn: $closePasswordLogin)
                    .onChange(of: closePasswordLogin) { _, isOn in
                        if isOn && !keyVerified {
                            closePasswordLogin = false
                            statusText = "请先完成密钥连接测试并通过，才能关闭密码登录"
                            statusKind = .warning
                        }
                    }

                HStack(spacing: 8) {
                    if isTesting || isDeploying || saving {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusKind.map { kind in security.presentation(for: kind).color.color } ?? palette.textSecondary.color)
                }

                Spacer(minLength: 0)

                HStack {
                    Button("取消") { dismiss() }
                        .buttonStyle(ThemedSecondaryButtonStyle())
                    Spacer()
#if os(macOS)
                    Button("生成并部署密钥") {
                        Task { await generateAndDeployKey() }
                    }
                    .buttonStyle(ThemedSecondaryButtonStyle())
                    .disabled(
                        isTesting || isDeploying || saving ||
                            !ConnectionSecurityPolicy.allowsLegacyQuickKeyDeployment
                    )
#endif
                    Button("测试密钥") {
                        Task { await testKeyConnection() }
                    }
                    .buttonStyle(ThemedSecondaryButtonStyle())
                    .disabled(
                        isTesting || saving || !hasValidKey ||
                            !ConnectionSecurityPolicy.allowsLegacyConnectionTest
                    )

                    Button("保存") {
                        Task { await save() }
                    }
                    .buttonStyle(ThemedPrimaryButtonStyle())
                    .disabled(isTesting || saving || !hasValidKey || (closePasswordLogin && !keyVerified))
                }
            }
            .padding(16)
            .navigationTitle("一键设置密钥")
            .background {
                ZStack {
                    AppChromeBackground()
                    palette.surfaceReadable.color.opacity(0.8)
                }
            }
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
                statusKind = .danger
            }
        }
#if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
#endif
    }

    private var hasValidKey: Bool {
        PrivateKeyValidator.isValid(privateKeyContent)
    }

    private func testKeyConnection() async {
        guard hasValidKey else { return }
        guard ConnectionSecurityPolicy.allowsLegacyConnectionTest else {
            statusText = "请先通过已验证连接流程确认服务器身份"
            statusKind = .warning
            return
        }
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
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
            statusKind = .success
        } else {
            keyVerified = false
            statusText = "密钥测试失败：\(result)"
            statusKind = .danger
        }
        #endif
    }

#if os(macOS)
    @MainActor
    private func generateAndDeployKey() async {
        guard !isDeploying else { return }
        guard ConnectionSecurityPolicy.allowsLegacyQuickKeyDeployment else {
            statusText = "安全密钥部署流程尚未启用"
            statusKind = .warning
            return
        }
        #if DEBUG && ORBITTERM_INTERNAL_LEGACY_NETWORK
        guard let old = try? vault.read(for: server.credentialID),
              !old.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusText = "生成部署失败：需要先保存密码凭据，才能把公钥写入远端"
            statusKind = .warning
            return
        }

        isDeploying = true
        keyVerified = false
        statusText = "正在生成本地 Ed25519 密钥..."
        statusKind = nil
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
                statusKind = .warning
                return
            }

            keyVerified = true
            statusText = "密钥已生成、部署并测试成功，可选择关闭密码登录"
            statusKind = .success
        } catch {
            statusText = "生成部署失败：\(error.localizedDescription)"
            statusKind = .danger
        }
        #endif
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
            statusKind = .warning
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
            statusKind = .danger
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
            accountID: session.username,
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
                statusKind = .danger
                return
            }
            privateKeyContent = key
            keyVerified = false
            statusText = "私钥已载入，请先测试"
            statusKind = nil
        } catch {
            statusText = "私钥文件读取失败: \(error.localizedDescription)"
            statusKind = .danger
        }
    }
}
