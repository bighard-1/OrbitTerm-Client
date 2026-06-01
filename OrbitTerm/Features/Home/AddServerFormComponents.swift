import SwiftUI

struct AddServerSectionCard<Content: View>: View {
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
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }
}

struct AddServerFormRow<Field: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var field: Field

    init(icon: String, title: String, @ViewBuilder field: () -> Field) {
        self.icon = icon
        self.title = title
        self.field = field()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .frame(width: 132, alignment: .leading)

            field
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AddServerTextField: View {
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
            .textFieldStyle(.roundedBorder)
#if os(iOS)
            .keyboardType(numeric ? .numberPad : .default)
            .textInputAutocapitalization(.never)
#endif
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AddServerSecureField: View {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        SecureField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AddServerStatusBar: View {
    let isTestingConnection: Bool
    let isConnectionVerified: Bool
    let testStatus: String
    let canTestConnection: Bool
    let onTest: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if isTestingConnection {
                ProgressView()
                    .controlSize(.small)
                Text("正在测试连接...")
                    .foregroundStyle(.secondary)
            } else if isConnectionVerified {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("连接测试成功，可直接保存并连接")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
                Text(testStatus)
                    .foregroundStyle(statusColor(testStatus))
            }

            Spacer()

            Button("测试连接") {
                onTest()
            }
            .buttonStyle(.bordered)
            .disabled(isTestingConnection || !canTestConnection)
        }
        .font(.system(.body, design: .rounded))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.thinMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.secondary.opacity(0.1)), alignment: .top)
    }

    private func statusColor(_ text: String) -> Color {
        if text.contains("成功") { return .green }
        if text.contains("失败") { return .red }
        if text.contains("测试") || text.contains("尚未") { return .secondary }
        return .secondary
    }
}
