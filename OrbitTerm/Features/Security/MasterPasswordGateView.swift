import SwiftUI

struct MasterPasswordGateView: View {
    @EnvironmentObject private var session: AppSession

    @StateObject private var orbitManager = OrbitManager()

    @State private var masterPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var message: String = ""

    var body: some View {
        NavigationStack {
            Form {
                if session.hasMasterPassword {
                    Section("验证主密码") {
                        SecureField("输入主密码", text: $masterPassword)
                    }

                    Section("操作") {
                        Button("验证并解锁") {
                            verify()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(masterPassword.isEmpty)
                    }
                } else {
                    Section("设置主密码") {
                        SecureField("主密码", text: $masterPassword)
                        SecureField("确认主密码", text: $confirmPassword)
                    }

                    Section("操作") {
                        Button("保存并解锁") {
                            setup()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(masterPassword.isEmpty || confirmPassword.isEmpty)
                    }
                }

                if !message.isEmpty {
                    Section("状态") {
                        Text(message)
                            .foregroundStyle(message.hasPrefix("成功") ? .green : .red)
                    }
                }
            }
            .navigationTitle("主密码")
        }
    }

    private func verify() {
        if session.verifyMasterPassword(masterPassword) {
            message = "成功: 主密码验证通过"
        } else {
            message = "失败: 主密码不正确"
        }
    }

    private func setup() {
        guard masterPassword == confirmPassword else {
            message = "失败: 两次输入不一致"
            return
        }

        do {
            _ = try orbitManager.encrypt(password: masterPassword, data: "master-password-check")
            try session.setupMasterPassword(masterPassword)
            message = "成功: 主密码已设置并通过 Rust 加密自检"
        } catch {
            message = "失败: \(error.localizedDescription)"
        }
    }
}
