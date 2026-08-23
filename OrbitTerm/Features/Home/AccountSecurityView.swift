import SwiftUI

/// Changes only the account login credential. Master-password rotation is kept
/// separate because it must atomically re-encrypt every cloud configuration.
struct AccountSecurityView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var serverStore: ServerStore
    @EnvironmentObject private var syncService: SyncService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appThemePalette) private var palette

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var isSubmitting = false
    @State private var feedback = ""

    @State private var currentMasterPassword = ""
    @State private var newMasterPassword = ""
    @State private var masterPasswordConfirmation = ""
    @State private var masterPasswordLoginConfirmation = ""
    @State private var isRotatingMasterPassword = false
    @State private var masterPasswordFeedback = ""
    @State private var securityTask: Task<Void, Never>?
    @State private var securityOwner = PageOperationOwner()
    @State private var showDiagnostics = false
    @State private var showingLeaveAccountConfirmation = false

    private var canSubmit: Bool {
        !currentPassword.isEmpty &&
            !newPassword.isEmpty &&
            newPassword == confirmation &&
            newPassword != currentPassword &&
            !isSubmitting && securityTask == nil
    }

    private var canRotateMasterPassword: Bool {
        !currentMasterPassword.isEmpty &&
            !newMasterPassword.isEmpty &&
            newMasterPassword == masterPasswordConfirmation &&
            newMasterPassword != currentMasterPassword &&
            !masterPasswordLoginConfirmation.isEmpty &&
            !isRotatingMasterPassword && securityTask == nil
    }

    var body: some View {
        Group {
#if os(macOS)
            macOSContent
#else
            formContent
#endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .orbitTermClearTransientSensitiveInput)) { _ in
            cancelSecurityOperation(.accountLocked)
            clearTransientPasswords()
        }
        .onDisappear { cancelSecurityOperation(.pageDisappeared) }
        .onChange(of: session.username) { _, _ in cancelSecurityOperation(.accountChanged) }
        .onChange(of: session.isAuthenticated) { _, authenticated in
            if !authenticated { cancelSecurityOperation(.accountSignedOut) }
        }
        .onChange(of: session.isUnlocked) { _, unlocked in
            if !unlocked { cancelSecurityOperation(.accountLocked) }
        }
#if os(macOS)
        .confirmationDialog(
            "退出或切换账户？",
            isPresented: $showingLeaveAccountConfirmation,
            titleVisibility: .visible
        ) {
            Button("退出并返回登录页", role: .destructive) {
                AccountSessionActions.leaveCurrentAccount(session: session, serverStore: serverStore)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前会话将断开；本机数据继续按账户隔离保存，不会交给下一个账户。")
        }
#endif
    }

    private func clearTransientPasswords() {
        currentPassword = ""
        newPassword = ""
        confirmation = ""
        currentMasterPassword = ""
        newMasterPassword = ""
        masterPasswordConfirmation = ""
        masterPasswordLoginConfirmation = ""
    }

    private var formContent: some View {
        Form {
            Section("当前账户") {
                LabeledContent("用户名") {
                    Text(session.username)
                        .textSelection(.enabled)
                }
                Text("登录密码用于账户登录；主密码用于本机与端到端加密配置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("登录密码") {
                SecureField("当前登录密码", text: $currentPassword)
                    .textContentType(.password)
                SecureField("新登录密码", text: $newPassword)
                    .textContentType(.newPassword)
                SecureField("确认新登录密码", text: $confirmation)
                    .textContentType(.newPassword)

                Text("新密码至少 12 位，并包含大写字母、小写字母、数字和特殊字符。修改后，其他设备需要重新登录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !confirmation.isEmpty, newPassword != confirmation {
                    Label("两次输入的新密码不一致", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if !feedback.isEmpty {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(feedback.hasPrefix("已") ? .green : .red)
                }

                Button(isSubmitting ? "正在更新…" : "更新登录密码") {
                    startPasswordChange()
                }
                .disabled(!canSubmit)
            }

            Section("主密码") {
                Text("主密码用于本地和端到端加密的配置。更换会在本机重新加密全部云端资产与最近删除记录；服务器只接收新的密文。完成后，其他设备必须更新客户端并使用新主密码重新解锁。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if session.hasAcceptedStagedMasterPasswordRotation {
                    Label("检测到已完成的云端轮换，等待本地钥匙串提交。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("完成本地主密码更新") {
                        finishPendingMasterPasswordCommit()
                    }
                    .disabled(isRotatingMasterPassword)
                } else {
                    SecureField("当前主密码", text: $currentMasterPassword)
                        .textContentType(.password)
                    SecureField("新主密码", text: $newMasterPassword)
                        .textContentType(.newPassword)
                    SecureField("确认新主密码", text: $masterPasswordConfirmation)
                        .textContentType(.newPassword)
                    SecureField("确认当前登录密码", text: $masterPasswordLoginConfirmation)
                        .textContentType(.password)

                    if !masterPasswordConfirmation.isEmpty, newMasterPassword != masterPasswordConfirmation {
                        Label("两次输入的新主密码不一致", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button(isRotatingMasterPassword ? "正在轮换…" : "轮换主密码并重新加密云端配置") {
                        startMasterPasswordRotation()
                    }
                    .disabled(!canRotateMasterPassword)
                }

                if !masterPasswordFeedback.isEmpty {
                    Text(masterPasswordFeedback)
                        .font(.caption)
                        .foregroundStyle(masterPasswordFeedback.hasPrefix("已") ? .green : .red)
                }
            }
        }
        .navigationTitle("个人信息管理")
#if os(iOS)
        .scrollContentBackground(.hidden)
        .background(AppChromeBackground())
#endif
    }

#if os(macOS)
    private var macOSContent: some View {
        ZStack {
            AppChromeBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    accountSummary
                    accountOperationsCard
                    loginPasswordCard
                    masterPasswordCard
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("个人信息管理")
    }

    private var accountSummary: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
                .foregroundStyle(palette.accentPrimary.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("当前账户")
                    .font(.headline)
                    .foregroundStyle(palette.textPrimary.color)
                Text(session.username)
                    .font(.body.weight(.medium))
                    .foregroundStyle(palette.textPrimary.color)
                    .textSelection(.enabled)
                Text("登录密码用于账户登录；主密码用于本机与端到端加密配置。")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .themedReadableSurface()
    }

    private var accountOperationsCard: some View {
        securityCard(
            title: "账户与同步",
            detail: syncService.lastSyncMessage.isEmpty ? "当前尚无同步状态。" : syncService.lastSyncMessage
        ) {
            HStack(spacing: 10) {
                Button("导出脱敏诊断") { showDiagnostics = true }
                    .buttonStyle(ThemedSecondaryButtonStyle())

                Spacer()
                Button("锁定工作站") {
                    Task {
                        for workspace in SessionManager.shared.tabs {
                            await SessionManager.shared.disconnect(session: workspace)
                        }
                        session.isUnlocked = false
                        dismiss()
                    }
                }
                .buttonStyle(ThemedSecondaryButtonStyle())
            }

            Divider()
            HStack {
                Text("需要在本机使用其他账户时，可安全退出并返回登录页。")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
                Spacer()
                Button("退出或切换账户", role: .destructive) {
                    showingLeaveAccountConfirmation = true
                }
                .buttonStyle(ThemedSecondaryButtonStyle())
            }
        }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsExportView() }
    }

    private var loginPasswordCard: some View {
        securityCard(
            title: "登录密码",
            detail: "修改后，其他设备需要重新登录。新密码至少 12 位，并包含大写字母、小写字母、数字和特殊字符。"
        ) {
            passwordField("当前登录密码", text: $currentPassword)
            passwordField("新登录密码", text: $newPassword)
            passwordField("确认新登录密码", text: $confirmation)

            if !confirmation.isEmpty, newPassword != confirmation {
                Label("两次输入的新密码不一致", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(SecuritySemanticPalette().warning.color)
            }

            if !feedback.isEmpty {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(feedback.hasPrefix("已") ? SecuritySemanticPalette().success.color : SecuritySemanticPalette().danger.color)
            }

            HStack {
                Spacer()
                Button(isSubmitting ? "正在更新…" : "更新登录密码") {
                    startPasswordChange()
                }
                .buttonStyle(ThemedPrimaryButtonStyle())
                .frame(minWidth: 170, maxWidth: 230)
                .disabled(!canSubmit)
            }
        }
    }

    private var masterPasswordCard: some View {
        securityCard(
            title: "主密码",
            detail: "轮换会在本机重新加密全部云端资产与最近删除记录；服务器只接收新的密文。完成后，其他设备必须更新客户端并使用新主密码重新解锁。"
        ) {
            if session.hasAcceptedStagedMasterPasswordRotation {
                Label("检测到已完成的云端轮换，等待本地钥匙串提交。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(SecuritySemanticPalette().warning.color)
                HStack {
                    Spacer()
                    Button("完成本地主密码更新") {
                        finishPendingMasterPasswordCommit()
                    }
                    .buttonStyle(ThemedPrimaryButtonStyle())
                    .frame(minWidth: 190, maxWidth: 250)
                    .disabled(isRotatingMasterPassword)
                }
            } else {
                passwordField("当前主密码", text: $currentMasterPassword)
                passwordField("新主密码", text: $newMasterPassword)
                passwordField("确认新主密码", text: $masterPasswordConfirmation)
                passwordField("确认当前登录密码", text: $masterPasswordLoginConfirmation)

                if !masterPasswordConfirmation.isEmpty, newMasterPassword != masterPasswordConfirmation {
                    Label("两次输入的新主密码不一致", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(SecuritySemanticPalette().warning.color)
                }

                HStack {
                    Spacer()
                    Button(isRotatingMasterPassword ? "正在轮换…" : "轮换主密码并重新加密云端配置") {
                        startMasterPasswordRotation()
                    }
                    .buttonStyle(ThemedPrimaryButtonStyle())
                    .frame(minWidth: 250, maxWidth: 330)
                    .disabled(!canRotateMasterPassword)
                }
            }

            if !masterPasswordFeedback.isEmpty {
                Text(masterPasswordFeedback)
                    .font(.caption)
                    .foregroundStyle(masterPasswordFeedback.hasPrefix("已") ? SecuritySemanticPalette().success.color : SecuritySemanticPalette().danger.color)
            }
        }
    }

    private func securityCard<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(palette.textPrimary.color)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(18)
        .themedReadableSurface()
    }

    private func passwordField(
        _ label: String,
        text: Binding<String>
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(palette.textPrimary.color)
                .frame(width: 132, alignment: .trailing)
            SecureField(label, text: text)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .themedInputSurface()
        }
        .accessibilityElement(children: .contain)
    }
#endif

    private var accountOperationScope: OperationScope {
        guard let account = AccountScope(username: session.username) else { return .anonymous }
        return .account(account.storageIdentifier)
    }

    private func startPasswordChange() {
        guard securityTask == nil, canSubmit else { return }
        let scope = accountOperationScope
        let lease = securityOwner.begin(scope: scope, timeout: PageOperationTimeout.authentication)
        securityTask = Task {
            await changePassword(lease: lease, scope: scope)
            finishSecurityOperation(lease, scope: scope)
        }
    }

    private func startMasterPasswordRotation() {
        guard securityTask == nil, canRotateMasterPassword else { return }
        let scope = accountOperationScope
        let lease = securityOwner.begin(scope: scope, timeout: PageOperationTimeout.assetMutation)
        securityTask = Task {
            await rotateMasterPassword(lease: lease, scope: scope)
            finishSecurityOperation(lease, scope: scope)
        }
    }

    private func finishSecurityOperation(_ lease: PageOperationLease, scope: OperationScope) {
        if securityOwner.timeoutReached(lease) {
            let wasRotatingMasterPassword = isRotatingMasterPassword
            securityOwner.cancel(.timedOut)
            isSubmitting = false
            isRotatingMasterPassword = false
            if wasRotatingMasterPassword {
                masterPasswordFeedback = "主密码轮换请求超时；本地恢复状态已保留，请检查网络后重试。"
            } else {
                feedback = "请求超时，请检查网络后重试。"
            }
            securityTask = nil
            return
        }
        guard securityOwner.accepts(lease, scope: scope) else { return }
        securityTask = nil
    }

    private func cancelSecurityOperation(_ reason: PageOperationCancellationReason) {
        securityOwner.cancel(reason)
        securityTask?.cancel()
        securityTask = nil
        isSubmitting = false
        isRotatingMasterPassword = false
        clearTransientPasswords()
    }

    private func accepts(_ lease: PageOperationLease, scope: OperationScope) -> Bool {
        !Task.isCancelled && securityOwner.accepts(lease, scope: scope)
    }

    private func changePassword(lease: PageOperationLease, scope: OperationScope) async {
        guard accepts(lease, scope: scope) else { return }
        guard canSubmit else { return }
        isSubmitting = true
        feedback = ""
        defer { if accepts(lease, scope: scope) { isSubmitting = false } }

        do {
            let result = try await NetworkService.shared.changePassword(
                currentPassword: currentPassword,
                newPassword: newPassword
            )
            guard accepts(lease, scope: scope) else { return }
            guard !result.accessTokenValue.isEmpty else {
                feedback = "服务未返回有效登录令牌，请重新登录。"
                return
            }
            try session.persistLogin(
                accessToken: result.accessTokenValue,
                refreshToken: result.refreshTokenValue,
                username: session.username
            )
            currentPassword = ""
            newPassword = ""
            confirmation = ""
            feedback = "已更新登录密码；其他设备需要重新登录。"
        } catch {
            guard accepts(lease, scope: scope) else { return }
            feedback = error.localizedDescription
        }
    }

    private func rotateMasterPassword(lease: PageOperationLease, scope: OperationScope) async {
        guard accepts(lease, scope: scope) else { return }
        guard canRotateMasterPassword else { return }
        isRotatingMasterPassword = true
        masterPasswordFeedback = ""
        defer { if accepts(lease, scope: scope) { isRotatingMasterPassword = false } }

        do {
            try await MasterPasswordRotationService.shared.rotate(
                currentMasterPassword: currentMasterPassword,
                newMasterPassword: newMasterPassword,
                currentLoginPassword: masterPasswordLoginConfirmation,
                session: session
            )
            guard accepts(lease, scope: scope) else { return }
            currentMasterPassword = ""
            newMasterPassword = ""
            masterPasswordConfirmation = ""
            masterPasswordLoginConfirmation = ""
            masterPasswordFeedback = "已完成主密码轮换；其他设备需要重新登录并使用新主密码解锁。"
        } catch {
            guard accepts(lease, scope: scope) else { return }
            masterPasswordFeedback = error.localizedDescription
        }
    }

    private func finishPendingMasterPasswordCommit() {
        do {
            try MasterPasswordRotationService.shared.finishPendingLocalCommit(session: session)
            masterPasswordFeedback = "已完成本地主密码更新。"
        } catch {
            masterPasswordFeedback = error.localizedDescription
        }
    }
}
