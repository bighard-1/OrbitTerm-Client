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

    @EnvironmentObject private var syncService: SyncService
    @StateObject private var orbitManager = OrbitManager()

    @State private var name: String = ""
    @State private var group: String = ""
    @State private var tagsText: String = ""
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

    @State private var isJumpHostEnabled = false
    @State private var jumpHost = ""
    @State private var jumpPortText = "22"
    @State private var jumpUsername = ""
    @State private var jumpAuthMethod: ServerAuthMethod = .password
    @State private var jumpAllowPasswordFallback = true
    @State private var jumpPassword = ""
    @State private var jumpPrivateKeyContent = ""
    @State private var jumpPrivateKeyPassphrase = ""
    @State private var jumpCredentialID = UUID()

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
    @State private var userOperationTask: Task<Void, Never>?
    @State private var userOperationOwner = PageOperationOwner()

    private let vault = CredentialVault.shared

    var body: some View {
        NavigationStack {
            editorShell
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
                startRestoreMatchedAsset(match)
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

    private var editorShell: some View {
        VStack(spacing: 0) {
            formHeader
            scrollableForm
            footer
        }
        .navigationTitle("")
        .background {
            ZStack {
                AppChromeBackground()
                palette.surfaceReadable.color.opacity(0.76)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
#if os(macOS)
        .frame(minWidth: 560, minHeight: 640)
#endif
        .background(validationObserver)
        .applyKeyboardDismissToolbar()
        .task { await initialLoad() }
        .onDisappear {
            cancelUserOperation(.pageDisappeared)
        }
        .onChange(of: session.username) { _, _ in
            cancelUserOperation(.accountChanged)
        }
        .onChange(of: session.isAuthenticated) { _, authenticated in
            if !authenticated {
                cancelUserOperation(.accountSignedOut)
            }
        }
        .onChange(of: session.isUnlocked) { _, unlocked in
            if !unlocked {
                cancelUserOperation(.accountLocked)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .orbitTermClearTransientSensitiveInput)) { _ in
            clearTransientCredentials()
        }
    }

    private func clearTransientCredentials() {
        password = ""
        privateKeyContent = ""
        privateKeyPassphrase = ""
        jumpPassword = ""
        jumpPrivateKeyContent = ""
        jumpPrivateKeyPassphrase = ""
        selectedKeyFileName = ""
        isConnectionVerified = false
    }

    private var scrollableForm: some View {
        ScrollView(.vertical, showsIndicators: true) {
            formContent
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
        }
        .frame(maxHeight: .infinity)
        .scrollDismissesKeyboard(.interactively)
        .font(.system(.body, design: .rounded))
    }

    private var footer: some View {
        AddServerFooter(
            isTestingConnection: isTestingConnection,
            isConnectionVerified: isConnectionVerified,
            testStatus: testStatus,
            canTestConnection: canTestConnection,
            isSaving: isSaving,
            saveButtonEnabled: saveButtonEnabled,
            onTest: startConnectionTest,
            onCancel: { dismiss() },
            onSave: startSaveAndConnect
        )
        .background(palette.surfaceReadable.color)
    }

    private var validationObserver: some View {
        ZStack {
            identityValidationObserver
            targetConnectionValidationObserver
            targetCredentialValidationObserver
            jumpConnectionValidationObserver
            jumpCredentialValidationObserver
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var identityValidationObserver: some View {
        Color.clear
            .onChange(of: name) { _, _ in invalidateVerification() }
            .onChange(of: host) { _, _ in invalidateVerification() }
            .onChange(of: username) { _, _ in invalidateVerification() }
    }

    private var targetConnectionValidationObserver: some View {
        Color.clear
            .onChange(of: portText) { _, newValue in
                let filtered = newValue.filter(\.isNumber)
                if filtered != newValue {
                    portText = filtered
                }
                invalidateVerification()
            }
            .onChange(of: authMethod) { _, _ in invalidateVerification() }
            .onChange(of: transport) { _, newValue in handleTransportChange(newValue) }
            .onChange(of: networkDeviceProfile) { _, _ in invalidateVerification() }
    }

    private var targetCredentialValidationObserver: some View {
        Color.clear
            .onChange(of: password) { _, _ in invalidateVerification() }
            .onChange(of: privateKeyContent) { _, _ in invalidateVerification() }
            .onChange(of: privateKeyPassphrase) { _, _ in invalidateVerification() }
            .onChange(of: allowPasswordFallback) { _, _ in invalidateVerification() }
    }

    private var jumpConnectionValidationObserver: some View {
        Color.clear
            .onChange(of: isJumpHostEnabled) { _, _ in invalidateVerification() }
            .onChange(of: jumpHost) { _, _ in invalidateVerification() }
            .onChange(of: jumpPortText) { _, newValue in
                let filtered = newValue.filter(\.isNumber)
                if filtered != newValue {
                    jumpPortText = filtered
                }
                invalidateVerification()
            }
            .onChange(of: jumpUsername) { _, _ in invalidateVerification() }
            .onChange(of: jumpAuthMethod) { _, _ in invalidateVerification() }
    }

    private var jumpCredentialValidationObserver: some View {
        Color.clear
            .onChange(of: jumpAllowPasswordFallback) { _, _ in invalidateVerification() }
            .onChange(of: jumpPassword) { _, _ in invalidateVerification() }
            .onChange(of: jumpPrivateKeyContent) { _, _ in invalidateVerification() }
            .onChange(of: jumpPrivateKeyPassphrase) { _, _ in invalidateVerification() }
    }

    private var formContent: some View {
        VStack(spacing: 14) {
            hostInformationSection
            jumpHostSection
            authenticationSection
            authenticationValidationMessage
            advancedSettingsSection
        }
    }

    private var hostInformationSection: some View {
        AddServerSectionCard(title: "主机信息") {
            AddServerFormRow(icon: "tag.fill", title: "名称") {
                AddServerTextField("例如：生产服务器", text: $name)
            }
            AddServerFormRow(icon: "tray.full.fill", title: "分组（可选）") {
                AddServerTextField("例如：线上", text: $group)
            }
            AddServerFormRow(icon: "tag", title: "标签（可选）") {
                AddServerTextField("例如：生产、Web、华东", text: $tagsText)
            }
            AddServerFormRow(icon: "network", title: "IP 地址") {
                AddServerTextField("例如：192.168.1.10", text: $host)
            }
            AddServerFormRow(icon: "point.3.connected.trianglepath.dotted", title: "端口") {
                AddServerTextField(
                    portPlaceholder,
                    text: $portText,
                    numeric: true
                )
            }
        }
    }

    private var authenticationSection: some View {
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
    }

    @ViewBuilder
    private var jumpHostSection: some View {
        if transport == .ssh {
            JumpHostConfigurationSection(
                isEnabled: $isJumpHostEnabled,
                host: $jumpHost,
                portText: $jumpPortText,
                username: $jumpUsername,
                authMethod: $jumpAuthMethod,
                allowPasswordFallback: $jumpAllowPasswordFallback,
                password: $jumpPassword,
                privateKeyContent: $jumpPrivateKeyContent,
                privateKeyPassphrase: $jumpPrivateKeyPassphrase
            )
        }
    }

    @ViewBuilder
    private var authenticationValidationMessage: some View {
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
    }

    private var advancedSettingsSection: some View {
        AddServerSectionCard(title: "高级设置") {
            DisclosureGroup("连接测试参数", isExpanded: $showAdvanced) {
                Stepper(value: $testTimeoutSec, in: 3...20) {
                    Text("连接测试超时：\(testTimeoutSec) 秒")
                }
                .padding(.top, 2)
            }
        }
    }

    private var formHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(editingServer == nil ? "添加服务器" : "编辑凭据")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.textPrimary.color)
                Text(editingServer == nil ? "保存后将建立经过身份验证的连接" : "更新资产连接与凭据设置")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
            }
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(palette.surfaceReadable.color)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.divider.color)
                .frame(height: 1)
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
            isJumpHostEnabled = false
        } else if newValue == .rdp {
            if portText == "22" || portText == "23" {
                portText = "3389"
            }
            authMethod = .password
            isJumpHostEnabled = false
        } else if portText == "23" {
            portText = "22"
        }
        invalidateVerification()
    }

    private var portPlaceholder: String {
        switch transport {
        case .ssh: "默认 22，可自定义高位端口"
        case .telnet: "默认 23，可自定义端口"
        case .rdp: "默认 3389，可自定义端口"
        }
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
        case .failure:
            testStatus = "无法读取私钥文件，请确认文件可访问且格式正确。"
        }
    }



    private var canSave: Bool {
        AddServerValidation.canSave(validationInput) && isJumpHostValid
    }

    private var parsedPort: Int? {
        AddServerValidation.parsedPort(from: portText)
    }

    private var saveButtonEnabled: Bool {
        canSave && (transport != .telnet || telnetEnabled)
    }

    private var canTestConnection: Bool {
        // In checked mode a legacy credential probe is intentionally unavailable,
        // but the button remains actionable so the user receives the explicit
        // security explanation from AddServerConnectionTester instead of a
        // silent disabled control.
        !isJumpHostEnabled && AddServerValidation.canTestConnection(validationInput)
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
            tags: ServerTagNormalizer.parse(tagsText),
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
            jumpHost: jumpHostConfiguration,
            jumpHostCredentials: jumpHostCredentials,
            editingServer: editingServer
        )
    }

    private var jumpHostConfiguration: JumpHostConfiguration? {
        guard isJumpHostEnabled,
              let port = AddServerValidation.parsedPort(from: jumpPortText) else {
            return nil
        }
        return JumpHostConfiguration(
            host: jumpHost,
            port: port,
            username: jumpUsername,
            authMethod: jumpAuthMethod,
            allowPasswordFallback: jumpAllowPasswordFallback,
            credentialID: jumpCredentialID
        )
    }

    private var jumpHostCredentials: ServerCredentials? {
        guard isJumpHostEnabled else { return nil }
        return ServerCredentials(
            password: jumpPassword,
            privateKeyContent: jumpPrivateKeyContent,
            privateKeyPassphrase: jumpPrivateKeyPassphrase
        )
    }

    private var isJumpHostValid: Bool {
        guard isJumpHostEnabled else { return true }
        guard transport == .ssh,
              let configuration = jumpHostConfiguration,
              configuration.isValid else {
            return false
        }
        let hasKey = AddServerValidation.hasValidPrivateKey(jumpPrivateKeyContent)
        if !jumpAllowPasswordFallback {
            return hasKey
        }
        switch jumpAuthMethod {
        case .password:
            return !jumpPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .key:
            return hasKey
        }
    }

    private var connectionTestInput: AddServerConnectionTestInput {
        AddServerConnectionTestInput(
            host: host,
            port: parsedPort ?? {
                switch transport {
                case .ssh: 22
                case .telnet: 23
                case .rdp: 3389
                }
            }(),
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
            if isJumpHostEnabled {
                testStatus = "跳板链路将在“保存并连接”时逐段验证服务器身份"
            } else {
                testStatus = ConnectionSecurityPolicy.allowsLegacyConnectionTest
                ? "尚未测试"
                : "保存并连接时将验证服务器身份"
            }
        }
    }

    private var accountOperationScope: OperationScope {
        guard let account = AccountScope(username: session.username) else { return .anonymous }
        return .account(account.storageIdentifier)
    }

    private func startConnectionTest() {
        guard userOperationTask == nil, canTestConnection else { return }
        let scope = accountOperationScope
        let lease = userOperationOwner.begin(scope: scope, timeout: PageOperationTimeout.assetMutation)
        userOperationTask = Task {
            await testConnection(lease: lease, scope: scope)
            completeUserOperation(lease, scope: scope)
        }
    }

    private func startSaveAndConnect() {
        guard userOperationTask == nil, canSave else { return }
        let scope = accountOperationScope
        let lease = userOperationOwner.begin(scope: scope, timeout: PageOperationTimeout.assetMutation)
        userOperationTask = Task {
            await saveAndConnect(lease: lease, scope: scope)
            completeUserOperation(lease, scope: scope)
        }
    }

    private func startRestoreMatchedAsset(_ match: DeletedIdentityMatch) {
        guard userOperationTask == nil else { return }
        let scope = accountOperationScope
        let lease = userOperationOwner.begin(scope: scope, timeout: PageOperationTimeout.assetMutation)
        userOperationTask = Task {
            await restoreMatchedAsset(match, lease: lease, scope: scope)
            completeUserOperation(lease, scope: scope)
        }
    }

    private func completeUserOperation(_ lease: PageOperationLease, scope: OperationScope) {
        if userOperationOwner.timeoutReached(lease) {
            userOperationOwner.cancel(.timedOut)
            isTestingConnection = false
            isSaving = false
            testStatus = "操作超时，请检查网络后重试。"
            userOperationTask = nil
            return
        }
        guard userOperationOwner.accepts(lease, scope: scope) else { return }
        userOperationTask = nil
    }

    private func cancelUserOperation(_ reason: PageOperationCancellationReason) {
        userOperationOwner.cancel(reason)
        userOperationTask?.cancel()
        userOperationTask = nil
        isTestingConnection = false
        isSaving = false
    }

    private func accepts(_ lease: PageOperationLease, scope: OperationScope) -> Bool {
        !Task.isCancelled && userOperationOwner.accepts(lease, scope: scope)
    }

    private func testConnection(lease: PageOperationLease, scope: OperationScope) async {
        guard accepts(lease, scope: scope) else { return }
        guard canTestConnection else { return }
        isTestingConnection = true
        defer {
            if accepts(lease, scope: scope) {
                isTestingConnection = false
            }
        }

        let result = await AddServerConnectionTester.test(input: connectionTestInput, orbitManager: orbitManager)
        guard accepts(lease, scope: scope) else { return }
        testStatus = result.status
        isConnectionVerified = result.isVerified
    }

    private func saveAndConnect(lease: PageOperationLease, scope: OperationScope) async {
        guard accepts(lease, scope: scope) else { return }
        guard canSave else { return }
        isSaving = true
        defer {
            if accepts(lease, scope: scope) {
                isSaving = false
            }
        }

        let draft = AddServerDraftBuilder.build(from: draftInput)
        if editingServer == nil,
           let deletedAssetID = await matchingDeletedAssetID(for: draft) {
            guard accepts(lease, scope: scope) else { return }
            deletedIdentityMatch = DeletedIdentityMatch(assetID: deletedAssetID, draft: draft)
            return
        }
        guard accepts(lease, scope: scope) else { return }
        finalizeSave(draft)
    }

    private func finalizeSave(_ draft: AddServerDraft) {
        guard store.addOrUpdate(
            draft.server,
            credentials: draft.credentials,
            jumpHostCredentials: draft.jumpHostCredentials
        ) else {
            saveErrorMessage = "凭据无法安全保存，资产未创建或更新。请检查系统钥匙串权限后重试。"
            return
        }
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
                jumpHostCredentials: draft.jumpHostCredentials,
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
                credentials: draft.credentials,
                jumpHostCredentials: draft.jumpHostCredentials
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
    private func restoreMatchedAsset(
        _ match: DeletedIdentityMatch,
        lease: PageOperationLease,
        scope: OperationScope
    ) async {
        guard accepts(lease, scope: scope) else { return }
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
            guard accepts(lease, scope: scope) else { return }
            guard let item = trash.first(where: { $0.assetID == match.assetID }) else {
                saveErrorMessage = "原资产已不在最近删除中，可选择作为新资产添加"
                return
            }
            let outcome = try await syncService.restoreRecentlyDeleted(
                item,
                store: store,
                accountID: session.username
            )
            guard accepts(lease, scope: scope) else { return }
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
            saveErrorMessage = "无法恢复资产，请稍后重试。"
        }
    }

    private func loadEditingServerIfNeeded() async {
        guard !didLoadEditingServer else { return }
        didLoadEditingServer = true
        guard let existing = editingServer else { return }
        let credentials = try? vault.read(for: existing.credentialID)
        applyInitialState(AddServerInitialState.editing(server: existing, credentials: credentials))
        if let jumpConfiguration = existing.jumpHost {
            isJumpHostEnabled = true
            jumpHost = jumpConfiguration.host
            jumpPortText = String(jumpConfiguration.port)
            jumpUsername = jumpConfiguration.username
            jumpAuthMethod = jumpConfiguration.authMethod
            jumpAllowPasswordFallback = jumpConfiguration.allowPasswordFallback
            jumpCredentialID = jumpConfiguration.credentialID
            let jumpCredentials = try? vault.read(for: jumpConfiguration.credentialID)
            jumpPassword = jumpCredentials?.password ?? ""
            jumpPrivateKeyContent = jumpCredentials?.privateKeyContent ?? ""
            jumpPrivateKeyPassphrase = jumpCredentials?.privateKeyPassphrase ?? ""
        }
    }

    private func applyInitialState(_ state: AddServerInitialState) {
        name = state.name
        group = state.group
        tagsText = state.tagsText
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
        jumpHostCredentials: ServerCredentials?,
        token: String?,
        masterPassword: String?,
        accountID: String
    ) async {
        if let message = await AddServerSilentSync.uploadStatusMessage(
            server: server,
            credentials: credentials,
            jumpHostCredentials: jumpHostCredentials,
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
            testStatus = "无法读取私钥文件，请确认文件可访问且格式正确。"
        }
    }
}
