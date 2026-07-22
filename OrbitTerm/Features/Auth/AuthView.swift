import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.appThemePalette) private var palette
    @Namespace private var modeAnimation

    @State private var isLoginMode: Bool = true
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var inviteCode: String = ""
    @State private var isLoading: Bool = false
    @State private var isPressingPrimary: Bool = false
    @State private var isShowingPassword: Bool = false
    @State private var message: String = ""
    @State private var messageKind: AuthStatusKind = .success
    @State private var shakeOffset: CGFloat = 0
    @State private var hiddenTapCount: Int = 0
    @State private var showServerConfigAlert: Bool = false
    @State private var showServerConfirmAlert: Bool = false
    @State private var customServerAddress: String = ""
    @State private var pendingServerAddress: String = ""

    private let network = NetworkService.shared

    private var canSubmit: Bool {
        guard !isLoading, !username.isEmpty, !password.isEmpty else { return false }
        guard !isLoginMode else { return true }
        let emailParts = username.split(separator: "@", omittingEmptySubsequences: false)
        return emailParts.count == 2
            && !emailParts[0].isEmpty
            && !emailParts[1].isEmpty
            && !inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && password.count >= 12
            && password.contains { $0.isUppercase }
            && password.contains { $0.isLowercase }
            && password.contains { $0.isNumber }
            && password.contains { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack {
                    AppChromeBackground()

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 24) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("OrbitTerm")
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                    .foregroundStyle(palette.textPrimary.color)
                                Text(isLoginMode ? "欢迎回来，继续你的终端旅程" : "创建账号，开启深空控制台")
                                    .foregroundStyle(palette.textSecondary.color)
                                    .font(.subheadline)
                                    .animation(.easeInOut(duration: 0.25), value: isLoginMode)
                            }

                            VStack(spacing: 18) {
                                AuthModeSwitcher(isLoginMode: $isLoginMode, namespace: modeAnimation)
                                credentialsForm
                                actionArea
                                bannerArea
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 26)
                            .themedGlassSurface()
                            .shadow(color: .black.opacity(0.14), radius: 20, x: 0, y: 14)
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 32)
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: proxy.size.height)
                    }
                }
            }
            .onChange(of: message) { _, newValue in
                if !newValue.isEmpty, messageKind == .failure {
                    withAnimation(.easeInOut(duration: 0.08).repeatCount(3, autoreverses: true)) {
                        shakeOffset += 1
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                hiddenTrigger
            }
            .alert("后端地址设置", isPresented: $showServerConfigAlert) {
                TextField("HTTPS 服务地址", text: $customServerAddress)
                Button("下一步") { prepareServerAddressConfirmation() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("隐藏菜单：仅用于调试或临时切换后端地址。")
            }
            .alert("安全确认", isPresented: $showServerConfirmAlert) {
                Button("确认切换", role: .destructive) {
                    do {
                        try network.updateBaseURL(pendingServerAddress)
                        setMessage("成功: 服务地址已更新", kind: .success)
                    } catch {
                        setMessage("失败: \(error.localizedDescription)", kind: .failure)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("新地址：\(pendingServerAddress)\n\n自定义后端可能会拦截您的加密凭据，请确认该端点来源可靠。")
            }
            .applyKeyboardDismissToolbar()
        }
    }

    private var credentialsForm: some View {
        VStack(spacing: 14) {
            AuthInputRow(
                icon: "envelope.fill",
                placeholder: "邮箱账号",
                text: $username,
                isSecure: false,
                showRevealToggle: false,
                isShowingPassword: $isShowingPassword
            )

            AuthInputRow(
                icon: "lock.fill",
                placeholder: "密码",
                text: $password,
                isSecure: !isShowingPassword,
                showRevealToggle: true,
                isShowingPassword: $isShowingPassword
            )

            if !isLoginMode {
                AuthInputRow(
                    icon: "ticket.fill",
                    placeholder: "管理员提供的邀请码",
                    text: $inviteCode,
                    isSecure: false,
                    showRevealToggle: false,
                    isShowingPassword: $isShowingPassword
                )
                Text("密码至少 12 位，且包含大小写字母、数字和特殊字符。")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var actionArea: some View {
        AuthPrimaryButton(
            isLoginMode: isLoginMode,
            isLoading: isLoading,
            isDisabled: !canSubmit,
            isPressing: $isPressingPrimary
        ) {
            Task { await submit() }
        }
    }

    @ViewBuilder
    private var bannerArea: some View {
        if !message.isEmpty {
            AuthStatusBanner(message: message, kind: messageKind, shakeOffset: shakeOffset)
        }
    }

    private var hiddenTrigger: some View {
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
                        customServerAddress = ""
                        showServerConfigAlert = true
                    }
                }
#if os(macOS)
            Button("") {
                customServerAddress = ""
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

    private func submit() async {
        isLoading = true
        defer { isLoading = false }

        let canonicalUsername = AccountIdentity.canonicalUsername(username)

        do {
            if !isLoginMode {
                try await network.register(username: canonicalUsername, password: password, inviteCode: inviteCode)
            }

            let loginData = try await network.login(username: canonicalUsername, password: password)
            try session.persistLogin(
                accessToken: loginData.accessTokenValue,
                refreshToken: loginData.refreshTokenValue,
                username: canonicalUsername
            )
            username = canonicalUsername
            password = ""
            inviteCode = ""
            setMessage("成功: 已获取 JWT", kind: .success)
        } catch {
            setMessage("失败: \(error.localizedDescription)", kind: .failure)
        }
    }

    private func prepareServerAddressConfirmation() {
        do {
            let normalized = try network.validatedBaseURLString(customServerAddress)
            pendingServerAddress = normalized
            if network.isDefaultEndpoint(normalized) {
                try network.updateBaseURL(normalized)
                setMessage("成功: 服务地址已更新", kind: .success)
                return
            }
            showServerConfirmAlert = true
        } catch {
            setMessage("失败: \(error.localizedDescription)", kind: .failure)
        }
    }

    private func setMessage(_ text: String, kind: AuthStatusKind) {
        message = text
        messageKind = kind
    }
}
