import SwiftUI

struct MasterPasswordGateView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var serverStore: ServerStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appThemePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var orbitManager = OrbitManager()

    @State private var masterPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var message: String = ""
    @State private var messageKind: SecurityStatusKind = .information
    @State private var shakeOffset: CGFloat = 0
    @State private var isBiometricAuthenticating = false
    @State private var isShowingAccountSwitchConfirmation = false
    @State private var biometricEnabled: Bool = false
    @State private var automaticBiometricAttemptedWhileActive = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AppChromeBackground()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 18) {
                        OrbitLogoBadgeView(size: 88)

                        Text(session.hasMasterPassword ? "验证主密码" : "设置主密码")
                            .font(.title2.bold())
                            .foregroundStyle(palette.textPrimary.color)

                        VStack(spacing: 12) {
                            secureInput(
                                placeholder: session.hasMasterPassword ? "输入主密码" : "主密码",
                                text: $masterPassword
                            )

                            if !session.hasMasterPassword {
                                secureInput(placeholder: "确认主密码", text: $confirmPassword)
                            }

                            Text("主密码用于解密您的服务器资产，确保您的数据安全。")
                                .font(.footnote)
                                .foregroundStyle(palette.textSecondary.color)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if !message.isEmpty {
                                Text(message)
                                    .font(.callout)
                                    .foregroundStyle(SecuritySemanticPalette().presentation(for: messageKind).color.color)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .modifier(ShakeEffect(animatableData: reduceMotion ? 0 : shakeOffset))
                                    .accessibilityLabel(message)
                            }
                        }

                        HStack(spacing: 10) {
#if os(macOS)
                            Button {
                                isShowingAccountSwitchConfirmation = true
                            } label: {
                                Label("使用其他账号", systemImage: "person.crop.circle.badge.arrow.counterclockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(ThemedSecondaryButtonStyle())
                            .controlSize(.large)
                            .accessibilityHint("断开当前账号的会话并返回登录页面")
#endif

                            Button(session.hasMasterPassword ? "验证并解锁" : "保存并解锁") {
                                submit()
                            }
                            .buttonStyle(ThemedPrimaryButtonStyle())
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                            .disabled(session.hasMasterPassword ? masterPassword.isEmpty : (masterPassword.isEmpty || confirmPassword.isEmpty))
                        }

                        if session.hasMasterPassword && biometricEnabled && BiometricAuthService.shared.isBiometricAvailable {
                            Button {
                                Task { await attemptBiometricUnlock(manual: true) }
                            } label: {
                                HStack(alignment: .center, spacing: 8) {
                                    Image(systemName: BiometricAuthService.shared.biometricIconName)
                                    Text(isBiometricAuthenticating ? SecurityOperationPresentation.biometricBusy : "使用生物识别解锁")
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(ThemedSecondaryButtonStyle())
                            .frame(maxWidth: .infinity)
                            .disabled(isBiometricAuthenticating)
                        }

                    }
                    .font(.system(.body, design: .rounded))
                    .padding(24)
                    .themedGlassSurface()
                    .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 12)
#if os(macOS)
                    // The workstation window is wider than the unlock form.
                    // Cap the form itself and center it in that window so the
                    // secure-input experience stays dialog-like and legible.
                    .frame(maxWidth: 520)
#endif
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    .padding(.horizontal, 16)
                }
            }
        }
        .onSubmit {
            submit()
        }
        .onChange(of: scenePhase) { _, newValue in
            if newValue != .active {
                clearSensitiveInputs()
            }
            if newValue == .background {
                automaticBiometricAttemptedWhileActive = false
            } else if newValue == .active {
                startAutomaticBiometricUnlockIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .orbitTermClearTransientSensitiveInput)) { _ in
            clearSensitiveInputs()
        }
        .onAppear {
            biometricEnabled = BiometricAuthService.shared.isEnabled(for: session.username)
            startAutomaticBiometricUnlockIfNeeded()
        }
        .onChange(of: session.username) { _, username in
            biometricEnabled = BiometricAuthService.shared.isEnabled(for: username)
            automaticBiometricAttemptedWhileActive = false
            startAutomaticBiometricUnlockIfNeeded()
        }
#if os(macOS)
        .confirmationDialog(
            "使用其他账号？",
            isPresented: $isShowingAccountSwitchConfirmation,
            titleVisibility: .visible
        ) {
            Button("切换账号", role: .destructive) {
                clearSensitiveInputs()
                AccountSessionActions.leaveCurrentAccount(
                    session: session,
                    serverStore: serverStore
                )
            }
            Button("继续解锁当前账号", role: .cancel) {}
        } message: {
            Text("将断开当前所有会话并返回登录页。本机资产、快捷指令和待同步操作继续按原账号隔离保存，不会交给下一个账号。")
        }
#endif
    }

    private func secureInput(placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(palette.textSecondary.color)
                .frame(width: 18)

            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .submitLabel(.go)
                .frame(minWidth: 0, maxWidth: .infinity)

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .themedInputSurface()
    }

    private func submit() {
        if session.hasMasterPassword {
            verify()
        } else {
            setup()
        }
    }

    private func verify() {
        let span = PerformanceSignpost.begin(.unlock)
        defer { span.finish() }
        if session.verifyMasterPassword(masterPassword) {
            setMessage("成功: 主密码验证通过", kind: .success)
            clearSensitiveInputs()
        } else {
            let unlockFailure = session.masterPasswordPersistenceError ?? "主密码不正确"
            setMessage(
                "失败: \(unlockFailure)",
                kind: .danger
            )
            triggerShake()
        }
    }

    private func setup() {
        let span = PerformanceSignpost.begin(.unlock)
        defer { span.finish() }
        guard masterPassword == confirmPassword else {
            setMessage("失败: 两次输入不一致", kind: .danger)
            triggerShake()
            return
        }

        do {
            _ = try orbitManager.encrypt(password: masterPassword, data: "master-password-check")
            try session.setupMasterPassword(masterPassword)
            setMessage("成功: 主密码已设置并通过 Rust 加密自检", kind: .success)
            clearSensitiveInputs()
        } catch {
            setMessage("失败: \(error.localizedDescription)", kind: .danger)
            triggerShake()
        }
    }

    private func triggerShake() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.08).repeatCount(3, autoreverses: true)) {
            shakeOffset += 1
        }
    }

    private func clearSensitiveInputs() {
        SecurityPrimitives.secureZero(&masterPassword)
        SecurityPrimitives.secureZero(&confirmPassword)
    }

    private func attemptBiometricUnlock(manual: Bool) async {
        guard session.hasMasterPassword, biometricEnabled else { return }
        guard BiometricAuthService.shared.isBiometricAvailable else {
            BiometricAuthService.shared.setEnabled(false, for: session.username)
            biometricEnabled = false
            setMessage(SecurityOperationPresentation.biometricUnavailable, kind: .warning)
            return
        }
        guard scenePhase == .active else { return }
        guard !isBiometricAuthenticating else { return }

        let span = PerformanceSignpost.begin(.unlock)
        defer { span.finish() }

        isBiometricAuthenticating = true
        defer { isBiometricAuthenticating = false }

        if !manual {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let outcome = await BiometricAuthService.shared.authenticate(accountID: session.username) {
            session.readMasterPassword()
        }
        switch outcome {
        case .success:
            session.markUnlockedByBiometric()
            setMessage(SecurityOperationPresentation.biometricUnlockSuccess, kind: .success)
        case let .failure(failure):
            if failure == .invalidated || failure == .unavailable {
                BiometricAuthService.shared.setEnabled(false, for: session.username)
                biometricEnabled = false
            }
            guard let feedback = SecurityOperationPresentation.biometricFailure(failure) else { return }
            if manual || failure == .invalidated || failure == .lockedOut || failure == .unavailable {
                setMessage(
                    feedback.message,
                    kind: feedback.kind == .failure ? .danger : .warning
                )
                if feedback.kind == .failure { triggerShake() }
            }
        }
    }

    private func startAutomaticBiometricUnlockIfNeeded() {
        guard scenePhase == .active,
              !automaticBiometricAttemptedWhileActive,
              session.hasMasterPassword,
              biometricEnabled else { return }
        automaticBiometricAttemptedWhileActive = true
        Task { await attemptBiometricUnlock(manual: false) }
    }

    private func setMessage(_ text: String, kind: SecurityStatusKind) {
        message = text
        messageKind = kind
    }
}

private struct OrbitLogoBadgeView: View {
    let size: CGFloat
    @Environment(\.appThemePalette) private var palette

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [palette.surfaceCritical.color, palette.surfaceInput.color],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [palette.accentPrimary.color, palette.accentSecondary.color],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: size * 0.11
                )
                .padding(size * 0.1)

            Text("OT")
                .font(.system(size: size * 0.3, weight: .heavy, design: .rounded))
                .foregroundStyle(palette.textPrimary.color)
        }
        .frame(width: size, height: size)
        .shadow(color: palette.accentPrimary.color.opacity(0.22), radius: 12, x: 0, y: 8)
    }
}

private struct ShakeEffect: GeometryEffect {
    var amount: CGFloat = 6
    var shakesPerUnit: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(
                translationX: amount * sin(animatableData * .pi * shakesPerUnit),
                y: 0
            )
        )
    }
}
