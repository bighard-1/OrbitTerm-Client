import SwiftUI

struct AuthModeSwitcher: View {
    @Binding var isLoginMode: Bool
    let namespace: Namespace.ID
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
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
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: 48)
    }

    private func modeButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if isSelected {
                    Capsule()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.12))
                        .matchedGeometryEffect(id: "modeSwitch", in: namespace)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            .frame(height: 40)
        }
        .buttonStyle(.plain)
    }
}

struct AuthInputRow: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    let isSecure: Bool
    let showRevealToggle: Bool
    @Binding var isShowingPassword: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    plainTextInput
                }
            }
            .applyInputPolish()

            if !text.isEmpty {
                Button {
                    text = ""
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
    private var plainTextInput: some View {
#if os(iOS)
        TextField(placeholder, text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
#else
        TextField(placeholder, text: $text)
#endif
    }
}

struct AuthPrimaryButton: View {
    let isLoginMode: Bool
    let isLoading: Bool
    let isDisabled: Bool
    @Binding var isPressing: Bool
    let onSubmit: () -> Void

    var body: some View {
        Button(action: onSubmit) {
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
                .frame(height: 50)
            }
            .frame(height: 52)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, alignment: .center)
        .scaleEffect(isPressing ? 0.98 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isPressing)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressing = true }
                .onEnded { _ in isPressing = false }
        )
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.65 : 1)
    }
}

struct AuthStatusBanner: View {
    let message: String
    let shakeOffset: CGFloat

    var body: some View {
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
        .modifier(AuthShakeEffect(animatableData: shakeOffset))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct AuthShakeEffect: GeometryEffect {
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
