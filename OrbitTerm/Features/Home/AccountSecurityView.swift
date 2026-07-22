import SwiftUI

/// Changes only the account login credential. Master-password rotation is kept
/// separate because it must atomically re-encrypt every cloud configuration.
struct AccountSecurityView: View {
    @EnvironmentObject private var session: AppSession
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

    private var canSubmit: Bool {
        !currentPassword.isEmpty &&
            !newPassword.isEmpty &&
            newPassword == confirmation &&
            newPassword != currentPassword &&
            !isSubmitting
    }

    private var canRotateMasterPassword: Bool {
        !currentMasterPassword.isEmpty &&
            !newMasterPassword.isEmpty &&
            newMasterPassword == masterPasswordConfirmation &&
            newMasterPassword != currentMasterPassword &&
            !masterPasswordLoginConfirmation.isEmpty &&
            !isRotatingMasterPassword
    }

    var body: some View {
#if os(macOS)
        macOSContent
#else
        formContent
#endif
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
                    Task { await changePassword() }
                }
                .disabled(!canSubmit)
            }

            Section("主密码") {
                Text("主密码用于本地和端到端加密的配置。更换会在本机重新加密全部云端资产与最近删除记录；服务器只接收新的密文。完成后，其他设备必须更新客户端并使用新主密码重新解锁。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if session.hasStagedMasterPasswordRotation {
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
                        Task { await rotateMasterPassword() }
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
    }

#if os(macOS)
    private var macOSContent: some View {
        ZStack {
            AppChromeBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    accountSummary
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
                    Task { await changePassword() }
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
            if session.hasStagedMasterPasswordRotation {
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
                        Task { await rotateMasterPassword() }
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

    private func changePassword() async {
        guard canSubmit else { return }
        isSubmitting = true
        feedback = ""
        defer { isSubmitting = false }

        do {
            let result = try await NetworkService.shared.changePassword(
                currentPassword: currentPassword,
                newPassword: newPassword
            )
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
            feedback = error.localizedDescription
        }
    }

    private func rotateMasterPassword() async {
        guard canRotateMasterPassword else { return }
        isRotatingMasterPassword = true
        masterPasswordFeedback = ""
        defer { isRotatingMasterPassword = false }

        do {
            try await MasterPasswordRotationService.shared.rotate(
                currentMasterPassword: currentMasterPassword,
                newMasterPassword: newMasterPassword,
                currentLoginPassword: masterPasswordLoginConfirmation,
                session: session
            )
            currentMasterPassword = ""
            newMasterPassword = ""
            masterPasswordConfirmation = ""
            masterPasswordLoginConfirmation = ""
            masterPasswordFeedback = "已完成主密码轮换；其他设备需要重新登录并使用新主密码解锁。"
        } catch {
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
