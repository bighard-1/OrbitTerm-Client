import SwiftUI
import UniformTypeIdentifiers

private struct DeletedIdentityMatch: Identifiable {
    let id = UUID()
    let assetID: UUID
    let draft: AddServerDraft
}

struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @Environment(\.appThemePalette) private var palette

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
    @AppStorage(TelnetAccessPolicy.enabledStorageKey) private var telnetEnabled: Bool = false
    @State private var testStatus = ConnectionSecurityPolicy.allowsLegacyConnectionTest
        ? "尚未测试"
        : "保存并连接时将验证服务器身份"
    @State private var isConnectionVerified = false

    @State private var showAdvanced = false
    @State private var testTimeoutSec = 8
    @State private var didLoadEditingServer = false
    @State private var didApplyPrefill = false
    @State private var deletedIdentityMatch: DeletedIdentityMatch?
    @State private var saveErrorMessage: String?

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

                        AddServerAuthSection(
                            username: $username,
                            authMethod: $authMethod,
                            transport: $transport,
                            networkDeviceProfile: $networkDeviceProfile,
                            password: $password,
                            keyInputMode: $keyInputMode,
                            privateKeyContent: $privateKeyContent,
                            privateKeyPassphrase: $privateKeyPassphrase,
                            allowPasswordFallback: $allowPasswordFallback,
                            telnetEnabled: telnetEnabled,
                            selectedKeyFileName: selectedKeyFileName,
                            privateKeyValidationMessage: privateKeyValidationMessage,
                            privateKeyValidationKind: privateKeyValidationKind
                        ) {
                            showKeyFileImporter = true
                        }

                        if authMethod == .password && password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("当前首选密码认证，请填写密码。")
                                .font(.caption)
                                .foregroundStyle(palette.textSecondary.color)
                        }

                        if transport == .ssh && authMethod == .key && !hasValidPrivateKey {
                            Text("当前首选密钥认证，请提供有效私钥。")
                                .font(.caption)
                                .foregroundStyle(palette.textSecondary.color)
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
                .frame(maxHeight: .infinity)
                .scrollDismissesKeyboard(.interactively)
                .font(.system(.body, design: .rounded))

                VStack(spacing: 0) {
                    AddServerStatusBar(
                        isTestingConnection: isTestingConnection,
                        isConnectionVerified: isConnectionVerified,
                        testStatus: testStatus,
                        canTestConnection: canTestConnection
                    ) {
                        Task { await testConnection() }
                    }

                    HStack(spacing: 10) {
                        Spacer(minLength: 0)

                        Button("取消") { dismiss() }
                            .buttonStyle(ThemedSecondaryButtonStyle())

                        Button(isSaving ? "保存中..." : "保存并连接") {
                            Task { await saveAndConnect() }
                        }
                        .buttonStyle(ThemedPrimaryButtonStyle())
                        .disabled(!saveButtonEnabled || isSaving)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
                .background(palette.surfaceReadable.color)
            }
            .navigationTitle(editingServer == nil ? "添加服务器" : "编辑凭据")
            .background {
                ZStack {
                    AppChromeBackground()
                    palette.surfaceReadable.color.opacity(0.76)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
#if os(macOS)
            .frame(minWidth: 620, minHeight: 720)
#endif
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
        .confirmationDialog(
            "发现最近删除中的相同连接",
            isPresented: Binding(
                get: { deletedIdentityMatch != nil },
                set: { if !$0 { deletedIdentityMatch = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("恢复原资产") {
                guard let match = deletedIdentityMatch else { return }
                deletedIdentityMatch = nil
                Task { await restoreMatchedAsset(match) }
            }
            Button("作为新资产添加") {
                guard let match = deletedIdentityMatch else { return }
                deletedIdentityMatch = nil
                finalizeSave(match.draft)
            }
            Button("取消", role: .cancel) { deletedIdentityMatch = nil }
        } message: {
            Text("该协议、主机、端口和用户名与最近删除中的资产一致。恢复可保留原资产身份；新建会生成独立资产。")
        }
        .alert("保存失败", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { saveErrorMessage = nil }
        } message: {
            Text(saveErrorMessage ?? "未知错误")
        }
    }

    private func handleTransportChange(_ newValue: ServerTransportProtocol) {
        if newValue == .telnet {
            if portText == "22" {
                portText = "23"
            }
            authMethod = .password
            if !telnetEnabled {
                testStatus = "Telnet 默认关闭，请先在设置中了解风险并手动启用"
            }
        } else if portText == "23" {
            portText = "22"
        }
        invalidateVerification()
    }

    private func initialLoad() async {
        applyPrefillIfNeeded()
        await loadEditingServerIfNeeded()
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



    private var canSave: Bool {
        AddServerValidation.canSave(validationInput)
    }

    private var parsedPort: Int? {
        AddServerValidation.parsedPort(from: portText)
    }

    private var saveButtonEnabled: Bool {
        canSave && (transport != .telnet || telnetEnabled)
    }

    private var canTestConnection: Bool {
        ConnectionSecurityPolicy.allowsLegacyConnectionTest &&
            AddServerValidation.canTestConnection(validationInput)
    }

    private var hasValidPrivateKey: Bool {
        AddServerValidation.hasValidPrivateKey(privateKeyContent)
    }

    private var privateKeyValidationMessage: String {
        PrivateKeyValidator.validationMessage(for: privateKeyContent)
    }

    private var privateKeyValidationKind: SecurityStatusKind? {
        guard !privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return hasValidPrivateKey ? .success : .danger
    }

    private var validationInput: AddServerValidationInput {
        AddServerValidationInput(
            name: name,
            host: host,
            portText: portText,
            username: username,
            authMethod: authMethod,
            transport: transport,
            allowPasswordFallback: allowPasswordFallback,
            password: password,
            privateKeyContent: privateKeyContent
        )
    }

    private var draftInput: AddServerDraftInput {
        AddServerDraftInput(
            name: name,
            group: group,
            host: host,
            port: parsedPort ?? 22,
            username: username,
            authMethod: authMethod,
            transport: transport,
            networkDeviceProfile: networkDeviceProfile,
            allowPasswordFallback: allowPasswordFallback,
            password: password,
            privateKeyContent: privateKeyContent,
            privateKeyPassphrase: privateKeyPassphrase,
            editingServer: editingServer
        )
    }

    private var connectionTestInput: AddServerConnectionTestInput {
        AddServerConnectionTestInput(
            host: host,
            port: parsedPort ?? (transport == .telnet ? 23 : 22),
            username: username,
            password: password,
            authMethod: authMethod,
            transport: transport,
            networkDeviceProfile: networkDeviceProfile,
            allowPasswordFallback: allowPasswordFallback,
            privateKeyContent: privateKeyContent,
            privateKeyPassphrase: privateKeyPassphrase,
            timeoutSeconds: testTimeoutSec
        )
    }

    private func invalidateVerification() {
        isConnectionVerified = false
        if !isTestingConnection {
            testStatus = ConnectionSecurityPolicy.allowsLegacyConnectionTest
                ? "尚未测试"
                : "保存并连接时将验证服务器身份"
        }
    }

    private func testConnection() async {
        guard canTestConnection else { return }
        isTestingConnection = true
        defer { isTestingConnection = false }

        let result = await AddServerConnectionTester.test(input: connectionTestInput, orbitManager: orbitManager)
        testStatus = result.status
        isConnectionVerified = result.isVerified
    }

    private func saveAndConnect() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }

        let draft = AddServerDraftBuilder.build(from: draftInput)
        if editingServer == nil, let deletedAssetID = await matchingDeletedAssetID(for: draft) {
            deletedIdentityMatch = DeletedIdentityMatch(assetID: deletedAssetID, draft: draft)
            return
        }
        finalizeSave(draft)
    }

    private func finalizeSave(_ draft: AddServerDraft) {
        store.addOrUpdate(draft.server, credentials: draft.credentials)
        onSaveAndConnect(draft.server)

        let token = session.readToken()
        let masterPassword = session.readMasterPassword()
        let accountID = session.username

        dismiss()
        session.showTransientStatus("已保存并连接")

        Task(priority: .background) {
            await silentSync(
                draft.server,
                credentials: draft.credentials,
                token: token,
                masterPassword: masterPassword,
                accountID: accountID
            )
        }
    }

    private func matchingDeletedAssetID(for draft: AddServerDraft) async -> UUID? {
        guard session.isAuthenticated,
              let masterPassword = session.readMasterPassword() else { return nil }
        do {
            let portable = draft.server.makePortableConfig(
                savedAtUnix: Int(Date().timeIntervalSince1970),
                credentials: draft.credentials
            )
            let fingerprint = try await SyncIdentityService.fingerprint(
                portable: portable,
                accountID: session.username,
                masterPassword: masterPassword
            )
            let matches = try await NetworkService.shared.findIdentityMatches(fingerprint: fingerprint)
            return matches.items.first(where: { $0.state == "deleted" }).flatMap {
                UUID(uuidString: $0.asset_id)
            }
        } catch {
            // 身份预检只用于改善冲突体验，失败时不得破坏离线优先的本地保存。
            return nil
        }
    }

    @MainActor
    private func restoreMatchedAsset(_ match: DeletedIdentityMatch) async {
        guard let masterPassword = session.readMasterPassword() else {
            saveErrorMessage = "主密码不可用，请重新解锁后再恢复"
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let trash = try await syncService.loadRecentlyDeleted(
                masterPassword: masterPassword,
                accountID: session.username
            )
            guard let item = trash.first(where: { $0.assetID == match.assetID }) else {
                saveErrorMessage = "原资产已不在最近删除中，可选择作为新资产添加"
                return
            }
            let outcome = try await syncService.restoreRecentlyDeleted(
                item,
                store: store,
                accountID: session.username
            )
            switch outcome {
            case .completed:
                guard let restored = store.servers.first(where: { $0.id == match.assetID }) else {
                    saveErrorMessage = "云端已恢复，正在等待本地同步"
                    return
                }
                onSaveAndConnect(restored)
                session.showTransientStatus("已恢复并连接原资产")
                dismiss()
            case .queued:
                session.showTransientStatus("恢复任务已排队，联网后自动完成")
            }
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    private func loadEditingServerIfNeeded() async {
        guard !didLoadEditingServer else { return }
        didLoadEditingServer = true
        guard let existing = editingServer else { return }
        let credentials = try? vault.read(for: existing.credentialID)
        applyInitialState(AddServerInitialState.editing(server: existing, credentials: credentials))
    }

    private func applyInitialState(_ state: AddServerInitialState) {
        name = state.name
        group = state.group
        host = state.host
        portText = state.portText
        username = state.username
        authMethod = state.authMethod
        transport = state.transport
        networkDeviceProfile = state.networkDeviceProfile
        allowPasswordFallback = state.allowPasswordFallback
        password = state.password
        privateKeyContent = state.privateKeyContent
        privateKeyPassphrase = state.privateKeyPassphrase
        keyInputMode = state.keyInputMode
        testStatus = state.testStatus
    }

    private func applyPrefillIfNeeded() {
        guard !didApplyPrefill else { return }
        didApplyPrefill = true
        guard editingServer == nil, let prefill else { return }
        applyInitialState(AddServerInitialState.prefill(prefill))
    }

    private func silentSync(
        _ server: ServerEntry,
        credentials: ServerCredentials,
        token: String?,
        masterPassword: String?,
        accountID: String
    ) async {
        if let message = await AddServerSilentSync.uploadStatusMessage(
            server: server,
            credentials: credentials,
            token: token,
            masterPassword: masterPassword,
            accountID: accountID,
            syncService: syncService
        ) {
            session.showTransientStatus(message)
        }
    }


    private func loadPrivateKeyFile(_ url: URL) {
        do {
            privateKeyContent = try AddServerKeyFileLoader.loadUTF8PrivateKey(from: url)
        } catch {
            testStatus = "私钥文件读取失败: \(error.localizedDescription)"
        }
    }
}
