import SwiftUI

struct AuthModeSwitcher: View {
    @Binding var isLoginMode: Bool
    let namespace: Namespace.ID
    let maximumWidth: CGFloat
    @Environment(\.appThemePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            modeButton(title: "登录", isSelected: isLoginMode) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    isLoginMode = true
                }
            }
            modeButton(title: "注册", isSelected: !isLoginMode) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    isLoginMode = false
                }
            }
        }
        .padding(4)
        .background(palette.surfaceInput.color, in: Capsule())
        .frame(width: maximumWidth)
        .frame(height: 48)
    }

    private func modeButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if isSelected {
                    Capsule()
                        .fill(palette.accentPrimary.color.opacity(0.18))
                        .matchedGeometryEffect(id: "modeSwitch", in: namespace)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.textPrimary.color)
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
    let maximumWidth: CGFloat
    @Environment(\.appThemePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { bounds in
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(palette.textSecondary.color)
                    .frame(width: 18)

                Group {
                    if isSecure {
                        SecureField(placeholder, text: $text)
                    } else {
                        plainTextInput
                    }
                }
                .applyInputPolish()
                .frame(minWidth: 0, maxWidth: .infinity)

                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(palette.textSecondary.color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除\(placeholder)")
                }

                if showRevealToggle {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isShowingPassword.toggle()
                        }
                    } label: {
                        Image(systemName: isShowingPassword ? "eye.slash.fill" : "eye.fill")
                            .foregroundStyle(palette.textSecondary.color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isShowingPassword ? "隐藏密码" : "显示密码")
                }
            }
            .frame(width: bounds.size.width, alignment: .leading)
        }
        .frame(height: 22)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(width: maximumWidth)
        .themedInputSurface()
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
    let maximumWidth: CGFloat
    let onSubmit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onSubmit) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.clear)
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
        .buttonStyle(ThemedPrimaryButtonStyle())
        .frame(width: maximumWidth)
        .scaleEffect(AppAccessibilityPresentation.usesDecorativeMotion(reduceMotion: reduceMotion) && isPressing ? 0.98 : 1.0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isPressing)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressing = true }
                .onEnded { _ in isPressing = false }
        )
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.65 : 1)
    }
}

enum AuthStatusKind {
    case success
    case failure

    var securityKind: SecurityStatusKind {
        self == .success ? .success : .danger
    }

    var symbol: String {
        self == .success ? "checkmark.circle.fill" : "xmark.octagon.fill"
    }
}

struct AuthStatusBanner: View {
    let message: String
    let kind: AuthStatusKind
    let shakeOffset: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbol)
            Text(message)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .securityStatusStyle(kind.securityKind)
        .modifier(AuthShakeEffect(animatableData: reduceMotion ? 0 : shakeOffset))
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
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
