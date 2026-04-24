import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var session: AppSession

    @State private var isLoginMode: Bool = true
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isLoading: Bool = false
    @State private var message: String = ""

    private let network = NetworkService.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("账户") {
                    TextField("用户名", text: $username)
                        .applyInputPolish()
                    SecureField("密码", text: $password)
                }

                Section("模式") {
                    Picker("认证方式", selection: $isLoginMode) {
                        Text("登录").tag(true)
                        Text("注册").tag(false)
                    }
                    .pickerStyle(.segmented)
                }

                Section("操作") {
                    Button(isLoginMode ? "登录" : "注册并登录") {
                        Task { await submit() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || username.isEmpty || password.isEmpty)

                    if isLoading {
                        ProgressView("请求中...")
                    }

                    if !message.isEmpty {
                        Text(message)
                            .foregroundStyle(message.hasPrefix("成功") ? .green : .red)
                    }
                }
            }
            .navigationTitle("登录 / 注册")
        }
    }

    private func submit() async {
        isLoading = true
        defer { isLoading = false }

        do {
            if !isLoginMode {
                try await network.register(username: username, password: password)
            }

            let token = try await network.login(username: username, password: password)
            try session.persistLogin(token: token, username: username)
            message = "成功: 已获取 JWT"
        } catch {
            message = "失败: \(error.localizedDescription)"
        }
    }
}
