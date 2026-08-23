import SwiftUI

struct AddServerSectionCard<Content: View>: View {
    @Environment(\.appThemePalette) private var palette
    let title: String
    @ViewBuilder var content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(palette.textPrimary.color)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(palette.surfaceReadable.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.borderGlass.color, lineWidth: 1)
        )
    }
}

struct AddServerFormRow<Field: View>: View {
    @Environment(\.appThemePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let icon: String
    let title: String
    @ViewBuilder var field: Field

    init(icon: String, title: String, @ViewBuilder field: () -> Field) {
        self.icon = icon
        self.title = title
        self.field = field()
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    label
                    field
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    label
                        .frame(width: 132, alignment: .leading)
                    field
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(palette.accentPrimary.color)
                // Form icons remain a fixed visual affordance. Letting their
                // glyph metrics scale with Dynamic Type makes them escape the
                // label column and collide with field borders.
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 24, height: 24, alignment: .center)
                .clipped()
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AddServerTextField: View {
    @Environment(\.appThemePalette) private var palette
    let placeholder: String
    @Binding var text: String
    var numeric = false

    init(_ placeholder: String, text: Binding<String>, numeric: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.numeric = numeric
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .foregroundStyle(palette.textPrimary.color)
            .themedInputSurface()
#if os(iOS)
            .keyboardType(numeric ? .numberPad : .default)
            .textInputAutocapitalization(.never)
#endif
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AddServerSecureField: View {
    @Environment(\.appThemePalette) private var palette
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        SecureField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .foregroundStyle(palette.textPrimary.color)
            .themedInputSurface()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AddServerStatusBar: View {
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security
    let isTestingConnection: Bool
    let isConnectionVerified: Bool
    let testStatus: String
    let canTestConnection: Bool
    let onTest: () -> Void

    var body: some View {
        let presentation = AssetConnectionTestPresentation.resolve(
            isTesting: isTestingConnection,
            isVerified: isConnectionVerified
        )
        HStack(spacing: 10) {
            if isTestingConnection {
                ProgressView()
                    .controlSize(.small)
                Text("正在测试连接...")
                    .foregroundStyle(security.information.color)
            } else if isConnectionVerified {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(security.success.color)
                Text("连接测试成功，可直接保存并连接")
                    .foregroundStyle(security.success.color)
            } else {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(palette.textSecondary.color)
                Text(testStatus)
                    .foregroundStyle(presentation.themeColor(in: security, fallback: palette).color)
            }

            Spacer()

            Button("测试连接") {
                onTest()
            }
            .buttonStyle(ThemedSecondaryButtonStyle())
            .disabled(isTestingConnection || !canTestConnection)
        }
        .font(.system(.body, design: .rounded))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(palette.surfaceGlassStrong.color)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(palette.divider.color), alignment: .top)
    }
}
