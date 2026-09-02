import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.appThemePalette) private var palette
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
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
    @State private var submitTask: Task<Void, Never>?
    @State private var submitOwner = PageOperationOwner()
    @State private var acceptedTerms = AuthTermsConsentStore.hasAcceptedCurrentVersion
    @State private var showTerms = false
    @State private var cooldownRemaining = 0
    @State private var cooldownTask: Task<Void, Never>?

    private let network = NetworkService.shared

    private var canSubmit: Bool {
        guard !isLoading, cooldownRemaining == 0, acceptedTerms,
              !username.isEmpty, !password.isEmpty else { return false }
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
        GeometryReader { proxy in
            // The main macOS window is deliberately wide for the workstation.
            // Authentication is a focused task, so keep its card readable rather
            // than stretching its fields across that workstation-sized window.
            let availableCardWidth = max(0, proxy.size.width - 32)
#if os(macOS)
            let cardWidth = min(availableCardWidth, 560)
#else
            // A full-width workstation-style form looks unbalanced on iPad.
            // Keep iPhone edge-to-edge for its limited width, while iPad uses
            // the same focused, readable form width as a native modal task.
            let cardWidth = horizontalSizeClass == .regular
                ? min(availableCardWidth, 640)
                : availableCardWidth
#endif
            let formWidth = max(0, cardWidth - 48)

            ZStack {
                AppChromeBackground()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                                Text("OrbitTerm")
                                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                                    .foregroundStyle(palette.textPrimary.color)
                                Text(isLoginMode ? "欢迎回来，继续你的终端旅程" : "创建账号，开启深空控制台")
                                    .foregroundStyle(palette.textSecondary.color)
                                    .font(.subheadline)
                                    .animation(.easeInOut(duration: 0.25), value: isLoginMode)
                        }
                        .frame(width: cardWidth, alignment: .center)

                        VStack(spacing: 18) {
                            AuthModeSwitcher(
                                isLoginMode: $isLoginMode,
                                namespace: modeAnimation,
                                maximumWidth: min(320, formWidth)
                            )
                            credentialsForm(width: formWidth)
                            actionArea(width: min(360, formWidth))
                            bannerArea
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 26)
                        .frame(width: cardWidth)
                        .themedGlassSurface()
                        .shadow(color: .black.opacity(0.14), radius: 20, x: 0, y: 14)
                    }
                    .padding(.vertical, 32)
                    .frame(width: proxy.size.width)
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
            .modifier(DevelopmentEndpointControls(network: network) { text, kind in
                setMessage(text, kind: kind)
            })
            .sheet(isPresented: $showTerms) {
                NavigationStack {
                    ScrollView {
                        Text(OrbitLegalTerms.fullText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                            .textSelection(.enabled)
                    }
                    .navigationTitle("使用条款、免责声明与隐私说明")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("同意并继续") {
                                acceptedTerms = true
                                AuthTermsConsentStore.recordCurrentVersion()
                                showTerms = false
                            }
                        }
                        ToolbarItem(placement: .cancellationAction) {
                            Button("返回") { showTerms = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .applyKeyboardDismissToolbar()
            .onReceive(NotificationCenter.default.publisher(for: .orbitTermClearTransientSensitiveInput)) { _ in
                password = ""
                inviteCode = ""
            }
            .onDisappear {
                cancelSubmit(.pageDisappeared)
                cooldownTask?.cancel()
            }
    }

    private func credentialsForm(width: CGFloat) -> some View {
        VStack(spacing: 14) {
            AuthInputRow(
                icon: "envelope.fill",
                placeholder: "邮箱账号",
                text: $username,
                isSecure: false,
                showRevealToggle: false,
                isShowingPassword: $isShowingPassword,
                maximumWidth: width
            )

            AuthInputRow(
                icon: "lock.fill",
                placeholder: "密码",
                text: $password,
                isSecure: !isShowingPassword,
                showRevealToggle: true,
                isShowingPassword: $isShowingPassword,
                maximumWidth: width
            )

            if !isLoginMode {
                AuthInputRow(
                    icon: "ticket.fill",
                    placeholder: "管理员提供的邀请码",
                    text: $inviteCode,
                    isSecure: false,
                    showRevealToggle: false,
                    isShowingPassword: $isShowingPassword,
                    maximumWidth: width
                )
                Text("密码至少 12 位，且包含大小写字母、数字和特殊字符。")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .center, spacing: 8) {
                Button {
                    if acceptedTerms {
                        acceptedTerms = false
                        AuthTermsConsentStore.clearCurrentVersion()
                    } else {
                        acceptedTerms = true
                        AuthTermsConsentStore.recordCurrentVersion()
                    }
                } label: {
                    Image(systemName: acceptedTerms ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundStyle(acceptedTerms ? palette.accentPrimary.color : palette.textSecondary.color)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(acceptedTerms ? "已同意使用条款、免责声明与隐私说明" : "尚未同意使用条款、免责声明与隐私说明")

                Text("已阅读并同意")
                    .foregroundStyle(palette.textSecondary.color)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 4)

                Button("查看法律条款") {
                    showTerms = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.accentPrimary.color)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("查看使用条款、免责声明与隐私说明")
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)

            if cooldownRemaining > 0 {
                Text("登录尝试过于频繁，请在 \(cooldownRemaining) 秒后重试。")
                    .font(.footnote)
                    .foregroundStyle(palette.accentSecondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func actionArea(width: CGFloat) -> some View {
        AuthPrimaryButton(
            isLoginMode: isLoginMode,
            isLoading: isLoading,
            isDisabled: !canSubmit,
            isPressing: $isPressingPrimary,
            maximumWidth: width
        ) {
            startSubmit()
        }
    }

    @ViewBuilder
    private var bannerArea: some View {
        if !message.isEmpty {
            AuthStatusBanner(message: message, kind: messageKind, shakeOffset: shakeOffset)
        }
    }

    private func startSubmit() {
        guard submitTask == nil, canSubmit else { return }
        let canonicalUsername = AccountIdentity.canonicalUsername(username)
        let retryAfter = LoginAttemptThrottle.retryAfterSeconds(for: canonicalUsername)
        guard retryAfter == 0 else {
            beginCooldown(seconds: retryAfter)
            setMessage("失败: 登录尝试过于频繁，请稍后重试。", kind: .failure)
            return
        }
        let lease = submitOwner.begin(scope: .anonymous, timeout: PageOperationTimeout.authentication)
        submitTask = Task {
            await submit(lease: lease)
            guard submitOwner.accepts(lease, scope: .anonymous) else { return }
            submitTask = nil
        }
    }

    private func cancelSubmit(_ reason: PageOperationCancellationReason) {
        submitOwner.cancel(reason)
        submitTask?.cancel()
        submitTask = nil
        isLoading = false
    }

    private func accepts(_ lease: PageOperationLease) -> Bool {
        !Task.isCancelled && submitOwner.accepts(lease, scope: .anonymous)
    }

    private func submit(lease: PageOperationLease) async {
        guard accepts(lease) else { return }
        isLoading = true
        defer {
            if accepts(lease) {
                isLoading = false
            }
        }

        let canonicalUsername = AccountIdentity.canonicalUsername(username)

        do {
            if !isLoginMode {
                try await PageOperationTimeout.perform(timeout: PageOperationTimeout.authentication) {
                    try await network.register(
                        username: canonicalUsername,
                        password: password,
                        inviteCode: inviteCode
                    )
                }
                guard accepts(lease) else { return }
            }

            let loginData = try await PageOperationTimeout.perform(timeout: PageOperationTimeout.authentication) {
                try await network.login(username: canonicalUsername, password: password)
            }
            guard accepts(lease) else { return }
            try session.persistLogin(
                accessToken: loginData.accessTokenValue,
                refreshToken: loginData.refreshTokenValue,
                username: canonicalUsername
            )
            username = canonicalUsername
            LoginAttemptThrottle.clear(for: canonicalUsername)
            AuthTermsConsentStore.recordCurrentVersion()
            password = ""
            inviteCode = ""
            setMessage("成功: 已获取 JWT", kind: .success)
        } catch {
            if submitOwner.timeoutReached(lease) {
                submitOwner.cancel(.timedOut)
                isLoading = false
                submitTask = nil
                setMessage("失败: 登录请求超时，请检查网络后重试。", kind: .failure)
                return
            }
            guard accepts(lease) else { return }
            if isLoginMode, LoginAttemptThrottle.isCredentialFailure(error) {
                let delay = LoginAttemptThrottle.recordFailure(for: canonicalUsername)
                if delay > 0 { beginCooldown(seconds: delay) }
            }
            setMessage("失败: \(error.localizedDescription)", kind: .failure)
        }
    }

    private func beginCooldown(seconds: Int) {
        cooldownTask?.cancel()
        cooldownRemaining = max(0, seconds)
        guard cooldownRemaining > 0 else { return }
        cooldownTask = Task { @MainActor in
            while !Task.isCancelled, cooldownRemaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                cooldownRemaining = LoginAttemptThrottle.retryAfterSeconds(
                    for: AccountIdentity.canonicalUsername(username)
                )
            }
        }
    }

    private func setMessage(_ text: String, kind: AuthStatusKind) {
        message = text
        messageKind = kind
    }
}

#if ORBITTERM_PUBLIC_RELEASE
private struct DevelopmentEndpointControls: ViewModifier {
    let network: NetworkService
    let report: (String, AuthStatusKind) -> Void

    func body(content: Content) -> some View { content }
}
#else
private struct DevelopmentEndpointControls: ViewModifier {
    let network: NetworkService
    let report: (String, AuthStatusKind) -> Void
    @State private var hiddenTapCount = 0
    @State private var showServerConfigAlert = false
    @State private var showServerConfirmAlert = false
    @State private var customServerAddress = ""
    @State private var pendingServerAddress = ""

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) { hiddenTrigger }
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
                        try network.updateApprovedCustomBaseURL(pendingServerAddress)
                        report("成功: 服务地址已更新", .success)
                    } catch {
                        report("失败: \(error.localizedDescription)", .failure)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("自托管服务域名：\(network.customEndpointHost(pendingServerAddress) ?? "未知")\n\n自定义后端将接收登录与加密同步请求。请仅在确认其来源、TLS 证书和运维责任可信时启用。")
            }
            .onReceive(NotificationCenter.default.publisher(for: .orbitTermClearTransientSensitiveInput)) { _ in
                pendingServerAddress = ""
                customServerAddress = ""
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

    private func prepareServerAddressConfirmation() {
        do {
            let normalized = try network.validatedBaseURLString(customServerAddress)
            pendingServerAddress = normalized
            if network.isDefaultEndpoint(normalized) {
                try network.updateBaseURL(normalized)
                report("成功: 服务地址已更新", .success)
                return
            }
            showServerConfirmAlert = true
        } catch {
            report("失败: \(error.localizedDescription)", .failure)
        }
    }
}
#endif

private enum AuthTermsConsentStore {
    static let version = "2026-08-22"
    private static let key = "orbitterm.legal-consent.version"

    static var hasAcceptedCurrentVersion: Bool {
        UserDefaults.standard.string(forKey: key) == version
    }

    static func recordCurrentVersion() {
        UserDefaults.standard.set(version, forKey: key)
    }

    static func clearCurrentVersion() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// A client-side speed bump for repeated credential failures. The server must
/// still enforce authoritative per-account/IP/device rate limits because a
/// modified client can bypass local controls.
enum LoginAttemptThrottle {
    private static let prefix = "orbitterm.auth-throttle.v1."

    static func retryAfterSeconds(for username: String, now: Date = Date()) -> Int {
        guard let scope = AccountScope(username: username) else { return 0 }
        let until = UserDefaults.standard.double(forKey: prefix + scope.storageIdentifier + ".until")
        return max(0, Int(ceil(until - now.timeIntervalSince1970)))
    }

    @discardableResult
    static func recordFailure(for username: String, now: Date = Date()) -> Int {
        guard let scope = AccountScope(username: username) else { return 0 }
        let base = prefix + scope.storageIdentifier
        let count = UserDefaults.standard.integer(forKey: base + ".count") + 1
        let delay = cooldownSeconds(failureCount: count)
        UserDefaults.standard.set(count, forKey: base + ".count")
        if delay > 0 {
            UserDefaults.standard.set(now.addingTimeInterval(TimeInterval(delay)).timeIntervalSince1970, forKey: base + ".until")
        }
        return delay
    }

    static func clear(for username: String) {
        guard let scope = AccountScope(username: username) else { return }
        let base = prefix + scope.storageIdentifier
        UserDefaults.standard.removeObject(forKey: base + ".count")
        UserDefaults.standard.removeObject(forKey: base + ".until")
    }

    static func cooldownSeconds(failureCount: Int) -> Int {
        LoginCooldownPolicy.seconds(failureCount: failureCount)
    }

    static func isCredentialFailure(_ error: Error) -> Bool {
        guard let networkError = error as? NetworkService.NetworkError else { return false }
        switch networkError {
        case .unauthorized: return true
        case let .unexpectedStatus(code): return code == 429
        default: return false
        }
    }
}
