import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var session: AppSession

    @State private var isLoginMode: Bool = true
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isLoading: Bool = false
    @State private var message: String = ""
    @State private var hiddenTapCount: Int = 0
    @State private var showServerConfigAlert: Bool = false
    @State private var customServerAddress: String = ""

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
            .overlay(alignment: .topLeading) {
                // 隐藏触发区域：左上角极小透明图标，连击 5 次打开地址设置。
                ZStack {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.clear)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            hiddenTapCount += 1
                            if hiddenTapCount >= 5 {
                                hiddenTapCount = 0
                                customServerAddress = network.currentBaseURLString
                                showServerConfigAlert = true
                            }
                        }
#if os(macOS)
                    // macOS 隐藏快捷键入口：Cmd + Option + S。
                    Button("") {
                        customServerAddress = network.currentBaseURLString
                        showServerConfigAlert = true
                    }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .opacity(0.001)
                    .frame(width: 1, height: 1)
#endif
                }
                .padding(.leading, 6)
                .padding(.top, 6)
            }
            .alert("后端地址设置", isPresented: $showServerConfigAlert) {
                TextField("https://server.orbitterm.com", text: $customServerAddress)
                Button("保存") {
                    do {
                        try network.updateBaseURL(customServerAddress)
                        message = "成功: 服务地址已更新"
                    } catch {
                        message = "失败: \(error.localizedDescription)"
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("隐藏菜单：仅用于调试或临时切换后端地址。")
            }
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
