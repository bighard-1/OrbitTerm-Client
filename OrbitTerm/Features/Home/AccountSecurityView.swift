import SwiftUI

/// Changes only the account login credential. Master-password rotation is kept
/// separate because it must atomically re-encrypt every cloud configuration.
struct AccountSecurityView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss

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
        Form {
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
        .navigationTitle("账户安全")
    }

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
