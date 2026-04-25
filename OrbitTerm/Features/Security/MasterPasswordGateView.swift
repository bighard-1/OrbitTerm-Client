import SwiftUI

struct MasterPasswordGateView: View {
    @EnvironmentObject private var session: AppSession

    @StateObject private var orbitManager = OrbitManager()

    @State private var masterPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var message: String = ""
    @State private var shakeOffset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.08, blue: 0.18),
                        Color.black
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 18) {
                        OrbitLogoBadgeView(size: 88)

                        Text(session.hasMasterPassword ? "验证主密码" : "设置主密码")
                            .font(.title2.bold())

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
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if !message.isEmpty {
                                Text(message)
                                    .font(.callout)
                                    .foregroundStyle(message.hasPrefix("成功") ? .green : .red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .modifier(ShakeEffect(animatableData: shakeOffset))
                            }
                        }

                        Button(session.hasMasterPassword ? "验证并解锁" : "保存并解锁") {
                            submit()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(session.hasMasterPassword ? masterPassword.isEmpty : (masterPassword.isEmpty || confirmPassword.isEmpty))
                    }
                    .font(.system(.body, design: .rounded))
                    .padding(30)
                    .frame(maxWidth: 520)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 12)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                }
            }
        }
        .onSubmit {
            submit()
        }
    }

    private func secureInput(placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .submitLabel(.go)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func submit() {
        if session.hasMasterPassword {
            verify()
        } else {
            setup()
        }
    }

    private func verify() {
        if session.verifyMasterPassword(masterPassword) {
            message = "成功: 主密码验证通过"
        } else {
            message = "失败: 主密码不正确"
            triggerShake()
        }
    }

    private func setup() {
        guard masterPassword == confirmPassword else {
            message = "失败: 两次输入不一致"
            triggerShake()
            return
        }

        do {
            _ = try orbitManager.encrypt(password: masterPassword, data: "master-password-check")
            try session.setupMasterPassword(masterPassword)
            message = "成功: 主密码已设置并通过 Rust 加密自检"
        } catch {
            message = "失败: \(error.localizedDescription)"
            triggerShake()
        }
    }

    private func triggerShake() {
        withAnimation(.easeInOut(duration: 0.08).repeatCount(3, autoreverses: true)) {
            shakeOffset += 1
        }
    }
}

private struct OrbitLogoBadgeView: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.05, green: 0.12, blue: 0.28), Color(red: 0.03, green: 0.06, blue: 0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [Color(red: 0.29, green: 0.64, blue: 1.0), Color(red: 0.48, green: 0.86, blue: 1.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: size * 0.11
                )
                .padding(size * 0.1)

            Text("OT")
                .font(.system(size: size * 0.3, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(red: 0.76, green: 0.9, blue: 1.0))
        }
        .frame(width: size, height: size)
        .shadow(color: .blue.opacity(0.25), radius: 12, x: 0, y: 8)
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
