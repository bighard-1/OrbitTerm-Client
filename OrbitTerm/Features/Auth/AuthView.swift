import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var modeAnimation

    @State private var isLoginMode: Bool = true
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isLoading: Bool = false
    @State private var isPressingPrimary: Bool = false
    @State private var isShowingPassword: Bool = false
    @State private var message: String = ""
    @State private var shakeOffset: CGFloat = 0
    @State private var hiddenTapCount: Int = 0
    @State private var showServerConfigAlert: Bool = false
    @State private var customServerAddress: String = ""

    private let network = NetworkService.shared

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color(red: 0.03, green: 0.08, blue: 0.18), .black]
                        : [Color(red: 0.78, green: 0.87, blue: 0.98), Color(red: 0.90, green: 0.94, blue: 0.99)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("OrbitTerm")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(isLoginMode ? "欢迎回来，继续你的终端旅程" : "创建账号，开启深空控制台")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                            .animation(.easeInOut(duration: 0.25), value: isLoginMode)
                    }

                    VStack(spacing: 18) {
                        modeSwitcher
                        credentialsForm
                        actionArea
                        bannerArea
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 26)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.12), radius: 20, x: 0, y: 14)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 32)
                .frame(maxWidth: 520)
            }
            .onChange(of: message) { _, newValue in
                if newValue.hasPrefix("失败") {
                    withAnimation(.easeInOut(duration: 0.08).repeatCount(3, autoreverses: true)) {
                        shakeOffset += 1
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                hiddenTrigger
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

    private var modeSwitcher: some View {
        HStack(spacing: 8) {
            modeButton(title: "登录", isSelected: isLoginMode) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    isLoginMode = true
                }
            }
            modeButton(title: "注册", isSelected: !isLoginMode) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    isLoginMode = false
                }
            }
        }
        .padding(4)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06), in: Capsule())
    }

    private func modeButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if isSelected {
                    Capsule()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.12))
                        .matchedGeometryEffect(id: "modeSwitch", in: modeAnimation)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
        }
        .buttonStyle(.plain)
    }

    private var credentialsForm: some View {
        VStack(spacing: 14) {
            inputRow(
                icon: "envelope.fill",
                placeholder: "用户名",
                text: $username,
                isSecure: false,
                showRevealToggle: false
            )

            inputRow(
                icon: "lock.fill",
                placeholder: "密码",
                text: $password,
                isSecure: !isShowingPassword,
                showRevealToggle: true
            )
        }
    }

    private func inputRow(
        icon: String,
        placeholder: String,
        text: Binding<String>,
        isSecure: Bool,
        showRevealToggle: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Group {
                if isSecure {
                    SecureField(placeholder, text: text)
                } else {
                    plainTextInput(placeholder: placeholder, text: text)
                }
            }
            .applyInputPolish()

            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if showRevealToggle {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isShowingPassword.toggle()
                    }
                } label: {
                    Image(systemName: isShowingPassword ? "eye.slash.fill" : "eye.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func plainTextInput(placeholder: String, text: Binding<String>) -> some View {
        #if os(iOS)
        TextField(placeholder, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
        #else
        TextField(placeholder, text: text)
        #endif
    }

    private var actionArea: some View {
        Button {
            Task { await submit() }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.21, green: 0.54, blue: 0.98), Color(red: 0.07, green: 0.36, blue: 0.84)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.85)
                    }
                    Text(isLoginMode ? "登录" : "注册并登录")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .padding(.vertical, 14)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressingPrimary ? 0.98 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isPressingPrimary)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressingPrimary = true }
                .onEnded { _ in isPressingPrimary = false }
        )
        .disabled(isLoading || username.isEmpty || password.isEmpty)
        .opacity((isLoading || username.isEmpty || password.isEmpty) ? 0.65 : 1)
    }

    @ViewBuilder
    private var bannerArea: some View {
        if !message.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: message.hasPrefix("失败") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(message.hasPrefix("失败") ? Color.red : Color.green)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(message.hasPrefix("失败") ? Color.red.opacity(0.12) : Color.green.opacity(0.12))
            )
            .modifier(ShakeEffect(animatableData: shakeOffset))
            .transition(.move(edge: .top).combined(with: .opacity))
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
                        customServerAddress = network.currentBaseURLString
                        showServerConfigAlert = true
                    }
                }
#if os(macOS)
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

private struct ShakeEffect: GeometryEffect {
    var amount: CGFloat = 4
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
