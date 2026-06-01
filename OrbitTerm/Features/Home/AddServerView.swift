import SwiftUI
import UniformTypeIdentifiers

private enum KeyInputMode: String, CaseIterable, Identifiable {
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

struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession

    @ObservedObject var store: ServerStore
    var editingServer: ServerEntry? = nil
    var prefill: ServerAddPrefill? = nil
    var onSaveAndConnect: (ServerEntry) -> Void

    @StateObject private var syncService = SyncService.shared
    @StateObject private var orbitManager = OrbitManager()

    @State private var name: String = ""
    @State private var group: String = ""
    @State private var host: String = ""
    @State private var portText: String = "22"
    @State private var username: String = ""
    @State private var authMethod: ServerAuthMethod = .password
    @State private var transport: ServerTransportProtocol = .ssh
    @State private var networkDeviceProfile: NetworkDeviceProfile = .auto
    @State private var allowPasswordFallback = true
    @State private var password: String = ""
    @State private var privateKeyContent: String = ""
    @State private var privateKeyPassphrase: String = ""
    @State private var keyInputMode: KeyInputMode = .paste
    @State private var showKeyFileImporter = false
    @State private var selectedKeyFileName: String = ""

    @State private var isTestingConnection = false
    @State private var isSaving = false
    @AppStorage("orbitterm.enable.telnet") private var telnetEnabled: Bool = true
    @State private var testStatus = "尚未测试"
    @State private var isConnectionVerified = false

    @State private var showAdvanced = false
    @State private var testTimeoutSec = 8
    @State private var didLoadEditingServer = false
    @State private var didApplyPrefill = false

    private let vault = CredentialVault.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 14) {
                        AddServerSectionCard(title: "主机信息") {
                            AddServerFormRow(icon: "tag.fill", title: "名称") {
                                AddServerTextField("例如：生产服务器", text: $name)
                            }
                            AddServerFormRow(icon: "tray.full.fill", title: "分组（可选）") {
                                AddServerTextField("例如：线上", text: $group)
                            }
                            AddServerFormRow(icon: "network", title: "IP 地址") {
                                AddServerTextField("例如：192.168.1.10", text: $host)
                            }
                            AddServerFormRow(icon: "point.3.connected.trianglepath.dotted", title: "端口") {
                                AddServerTextField("默认 22，可自定义高位端口", text: $portText, numeric: true)
                            }
                        }

                        authSection

                        if authMethod == .password && password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("当前首选密码认证，请填写密码。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if transport == .ssh && authMethod == .key && !hasValidPrivateKey {
                            Text("当前首选密钥认证，请提供有效私钥。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        

                        AddServerSectionCard(title: "高级设置") {
                            DisclosureGroup("连接测试参数", isExpanded: $showAdvanced) {
                                Stepper(value: $testTimeoutSec, in: 3...20) {
                                    Text("连接测试超时：\(testTimeoutSec) 秒")
                                }
                                .padding(.top, 2)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }
                .scrollDismissesKeyboard(.interactively)
                .font(.system(.body, design: .rounded))

                AddServerStatusBar(
                    isTestingConnection: isTestingConnection,
                    isConnectionVerified: isConnectionVerified,
                    testStatus: testStatus,
                    canTestConnection: canTestConnection
                ) {
                    Task { await testConnection() }
                }

                HStack(spacing: 10) {
                    Button("取消") { dismiss() }
                        .buttonStyle(.bordered)

                    Button(isSaving ? "保存中..." : "保存并连接") {
                        Task { await saveAndConnect() }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: saveButtonEnabled
                                        ? [Color(red: 0.25, green: 0.58, blue: 1.0), Color(red: 0.09, green: 0.38, blue: 0.88)]
                                        : [Color.gray.opacity(0.45), Color.gray.opacity(0.4)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .foregroundStyle(.white)
                    .disabled(!saveButtonEnabled || isSaving)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .navigationTitle(editingServer == nil ? "添加服务器" : "编辑凭据")
            .background(.ultraThinMaterial)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
#if os(macOS)
            .frame(minWidth: 500, minHeight: 650)
#endif
            .padding(12)
            .onChange(of: name) { _, _ in invalidateVerification() }
            .onChange(of: host) { _, _ in invalidateVerification() }
            .onChange(of: username) { _, _ in invalidateVerification() }
            .onChange(of: portText) { _, newValue in
                let filtered = newValue.filter(\.isNumber)
                if filtered != newValue {
                    portText = filtered
                }
                invalidateVerification()
            }
            .onChange(of: authMethod) { _, _ in invalidateVerification() }
            .onChange(of: transport) { _, newValue in
                handleTransportChange(newValue)
            }
            .onChange(of: networkDeviceProfile) { _, _ in invalidateVerification() }
            .onChange(of: password) { _, _ in invalidateVerification() }
            .onChange(of: privateKeyContent) { _, _ in invalidateVerification() }
            .onChange(of: privateKeyPassphrase) { _, _ in invalidateVerification() }
            .applyKeyboardDismissToolbar()
            .onChange(of: allowPasswordFallback) { _, _ in invalidateVerification() }
            .task {
                await initialLoad()
            }
        }
        .fileImporter(
            isPresented: $showKeyFileImporter,
            allowedContentTypes: [.data, .plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            handleKeyFileImport(result)
        }
    }

    private func handleTransportChange(_ newValue: ServerTransportProtocol) {
        if newValue == .telnet {
            if portText == "22" {
                portText = "23"
            }
            authMethod = .password
        } else if portText == "23" {
            portText = "22"
        }
        invalidateVerification()
    }

    private func initialLoad() async {
        applyPrefillIfNeeded()
        await loadEditingServerIfNeeded()
        if !telnetEnabled, transport == .telnet {
            transport = .ssh
            if portText == "23" {
                portText = "22"
            }
        }
    }

    private func handleKeyFileImport(_ result: Result<[URL], Error>) {
        guard keyInputMode == .file else { return }
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            selectedKeyFileName = url.lastPathComponent
            loadPrivateKeyFile(url)
        case let .failure(error):
            testStatus = "私钥文件读取失败: \(error.localizedDescription)"
        }
    }

    private var authSection: some View {
        AddServerSectionCard(title: "认证") {
            AddServerFormRow(icon: "person.fill", title: "用户名") {
                AddServerTextField("例如：root", text: $username)
            }

            AddServerFormRow(icon: "switch.2", title: "认证方式") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("认证方式", selection: $authMethod) {
                        ForEach(ServerAuthMethod.allCases) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(transport == .telnet)

                    if transport == .telnet {
                        Text("Telnet 使用文本提示符自动登录，认证方式固定为密码。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            AddServerFormRow(icon: "network", title: "传输协议") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("传输协议", selection: $transport) {
                        ForEach(ServerTransportProtocol.allCases) { proto in
                            Text(proto.displayName).tag(proto)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(!telnetEnabled)

                    if !telnetEnabled {
                        Text("Telnet 已在设置中禁用，仅可使用 SSH。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if transport == .telnet {
                telnetProfileSection
            }

            AddServerFormRow(icon: "lock.fill", title: "密码") {
                AddServerSecureField(transport == .telnet ? "用于自动应答 Password 提示" : "可选：SSH 密码", text: $password)
            }

            if transport == .ssh {
                sshCredentialOptions
            } else {
                Text("Telnet 密码仅存储在系统钥匙串，连接时用于自动应答设备登录提示符。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var telnetProfileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            AddServerFormRow(icon: "switch.2", title: "设备模板") {
                Picker("设备模板", selection: $networkDeviceProfile) {
                    ForEach(NetworkDeviceProfile.allCases) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .labelsHidden()
            }

            Text("Telnet 无标准认证协议，OrbitTerm 会根据模板识别 Username/Password 等提示符并自动应答。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sshCredentialOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            AddServerFormRow(icon: "switch.2", title: "密钥输入") {
                Picker("密钥输入", selection: $keyInputMode) {
                    ForEach(KeyInputMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            AddServerFormRow(icon: "key.fill", title: "私钥内容") {
                VStack(alignment: .leading, spacing: 8) {
                    if keyInputMode == .file {
                        Button {
                            showKeyFileImporter = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.badge.plus")
                                Text(selectedKeyFileName.isEmpty ? "选择私钥文件" : selectedKeyFileName)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    TextEditor(text: $privateKeyContent)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120, maxHeight: 180)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Text(privateKeyValidationMessage)
                        .font(.caption)
                        .foregroundStyle(privateKeyValidationColor)
                }
            }

            AddServerFormRow(icon: "lock.shield.fill", title: "私钥口令") {
                AddServerSecureField("可选：用于解密受保护私钥", text: $privateKeyPassphrase)
            }

            AddServerFormRow(icon: "shield.lefthalf.filled", title: "登录策略") {
                Toggle(
                    "仅允许密钥登录",
                    isOn: Binding(
                        get: { !allowPasswordFallback },
                        set: { allowPasswordFallback = !$0 }
                    )
                )
                .toggleStyle(.switch)
            }

            if !allowPasswordFallback {
                Text("已开启仅密钥模式：连接时将强制跳过密码认证。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("支持 OPENSSH/PEM 私钥。密码、私钥内容与口令仅存储在系统钥匙串。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }


    private var canSave: Bool {
        let baseValid = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            isPortValid &&
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard baseValid else { return false }
        if transport == .telnet {
            return !password.isEmpty
        }
        if !allowPasswordFallback && !hasValidPrivateKey {
            return false
        }

        switch authMethod {
        case .password:
            return !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .key:
            return hasValidPrivateKey
        }
    }

    private var parsedPort: Int? {
        Int(portText)
    }

    private var isPortValid: Bool {
        guard let p = parsedPort else { return false }
        return (1...65535).contains(p)
    }

    private var saveButtonEnabled: Bool {
        canSave
    }

    private var canTestConnection: Bool {
        let baseReady = !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard baseReady else { return false }
        if transport == .telnet {
            return !password.isEmpty
        }

        if !allowPasswordFallback {
            return hasValidPrivateKey
        }

        if !password.isEmpty || hasValidPrivateKey {
            return true
        }
        return false
    }

    private var isPrivateKeyFormatValid: Bool {
        let key = privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        let pattern = #"(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*-----END [A-Z0-9 ]*PRIVATE KEY-----"#
        return key.range(of: pattern, options: .regularExpression) != nil
    }

    private var hasValidPrivateKey: Bool {
        let key = privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return !key.isEmpty && isPrivateKeyFormatValid
    }

    private var privateKeyValidationMessage: String {
        if privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "未提供私钥（可选）"
        }
        return isPrivateKeyFormatValid ? "私钥格式校验通过" : "私钥格式不合法，需包含 BEGIN/END PRIVATE KEY"
    }

    private var privateKeyValidationColor: Color {
        let key = privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            return .secondary
        }
        return isPrivateKeyFormatValid ? .green : .red
    }

    private func invalidateVerification() {
        isConnectionVerified = false
        if !isTestingConnection {
            testStatus = "尚未测试"
        }
    }

    private func testConnection() async {
        guard canTestConnection else { return }
        isTestingConnection = true
        defer { isTestingConnection = false }

        if transport == .telnet {
            let probe = TelnetClient(host: host, port: parsedPort ?? 23)
            let autoLogin = TelnetClient.AutoLoginConfig(
                username: username,
                password: password,
                profile: networkDeviceProfile
            )
            let ok = await probe.connect(autoLogin: autoLogin, onData: { _ in }, onState: { _ in })
            await probe.disconnect()
            if ok {
                testStatus = autoLogin.isEnabled ? "连接测试成功 (Telnet，已尝试自动登录)" : "连接测试成功 (Telnet 端口可达)"
                isConnectionVerified = true
            } else {
                testStatus = "连接测试失败: Telnet 端口不可达"
                isConnectionVerified = false
            }
            return
        }

        do {
            let result = try await withThrowingTaskGroup(of: String.self) { group in
                let keyContent = privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines)
                let keyPassphrase = privateKeyPassphrase
                group.addTask(priority: .userInitiated) {
                    await orbitManager.testConnectionAsync(
                        ip: host,
                        port: parsedPort ?? 22,
                        username: username,
                        password: password,
                        privateKeyContent: keyContent,
                        privateKeyPassphrase: keyPassphrase,
                        allowPasswordFallback: allowPasswordFallback
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(testTimeoutSec) * 1_000_000_000)
                    throw SFTPError.timeout
                }

                guard let first = try await group.next() else {
                    throw SFTPError.invalidResponse
                }
                group.cancelAll()
                return first
            }

            if result.hasPrefix("成功") {
                testStatus = "连接测试成功"
                isConnectionVerified = true
            } else {
                testStatus = result
                isConnectionVerified = false
            }
        } catch {
            testStatus = "连接测试失败: \(error.localizedDescription)"
            isConnectionVerified = false
        }
    }

    private func saveAndConnect() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }

        let credentials = ServerCredentials(
            password: password,
            privateKeyContent: transport == .ssh ? privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            privateKeyPassphrase: transport == .ssh ? privateKeyPassphrase : ""
        )

        let server: ServerEntry
        if let existing = editingServer {
            server = ServerEntry(
                id: existing.id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                group: group.trimmingCharacters(in: .whitespacesAndNewlines),
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: parsedPort ?? 22,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                authMethod: transport == .telnet ? .password : authMethod,
                transport: transport,
                networkDeviceProfile: networkDeviceProfile,
                allowPasswordFallback: transport == .telnet ? true : allowPasswordFallback,
                credentialID: existing.credentialID,
                createdAt: existing.createdAt
            )
        } else {
            server = ServerEntry(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                group: group.trimmingCharacters(in: .whitespacesAndNewlines),
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: parsedPort ?? 22,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                authMethod: transport == .telnet ? .password : authMethod,
                transport: transport,
                networkDeviceProfile: networkDeviceProfile,
                allowPasswordFallback: transport == .telnet ? true : allowPasswordFallback
            )
        }

        store.addOrUpdate(server, credentials: credentials)
        onSaveAndConnect(server)

        let token = session.readToken()
        let masterPassword = session.readMasterPassword()

        dismiss()
        session.showTransientStatus("已保存并连接")

        Task(priority: .background) {
            await silentSync(server, credentials: credentials, token: token, masterPassword: masterPassword)
        }
    }

    private func loadEditingServerIfNeeded() async {
        guard !didLoadEditingServer else { return }
        didLoadEditingServer = true
        guard let existing = editingServer else { return }

        name = existing.name
        group = existing.group
        host = existing.host
        portText = String(existing.port)
        username = existing.username
        authMethod = existing.authMethod
        transport = existing.transport
        networkDeviceProfile = existing.networkDeviceProfile
        if transport == .telnet {
            authMethod = .password
        }
        allowPasswordFallback = existing.allowPasswordFallback

        if let credentials = try? vault.read(for: existing.credentialID) {
            password = credentials.password
            privateKeyContent = credentials.privateKeyContent
            privateKeyPassphrase = credentials.privateKeyPassphrase
        }

        if !privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            keyInputMode = .paste
        }
        testStatus = "已载入现有凭据"
    }

    private func applyPrefillIfNeeded() {
        guard !didApplyPrefill else { return }
        didApplyPrefill = true
        guard editingServer == nil, let prefill else { return }

        name = prefill.name
        group = prefill.group
        host = prefill.host
        portText = String(prefill.port)
        username = prefill.username
        testStatus = "已通过链接填充连接信息，请先测试再保存"
    }

    private func silentSync(_ server: ServerEntry, credentials: ServerCredentials, token: String?, masterPassword: String?) async {
        guard let token, let masterPassword else {
            session.showTransientStatus("已本地保存，登录后将自动同步")
            return
        }

        let portable = server.makePortableConfig(savedAtUnix: Int(Date().timeIntervalSince1970), credentials: credentials)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        guard let jsonData = try? encoder.encode(portable),
              let plaintext = String(data: jsonData, encoding: .utf8) else {
            session.showTransientStatus("同步暂不可用，已本地保存")
            return
        }

        let vectorClock = ["client": Int(Date().timeIntervalSince1970)]
        let ok = await syncService.uploadEncryptedConfig(
            token: token,
            masterPassword: masterPassword,
            plaintextConfig: plaintext,
            vectorClock: vectorClock,
            allowQueueOnNetworkFailure: true
        )

        if !ok {
            session.showTransientStatus("云端同步失败，稍后自动重试")
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
                testStatus = "私钥文件不是 UTF-8 文本"
                return
            }
            privateKeyContent = key
        } catch {
            testStatus = "私钥文件读取失败: \(error.localizedDescription)"
        }
    }
}
