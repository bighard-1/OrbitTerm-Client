import SwiftUI

/// Native form section for one SSH jump host. It does not initiate a network
/// operation; all values are later passed to the checked connection pipeline.
struct JumpHostConfigurationSection: View {
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security

    @Binding var isEnabled: Bool
    @Binding var host: String
    @Binding var portText: String
    @Binding var username: String
    @Binding var authMethod: ServerAuthMethod
    @Binding var allowPasswordFallback: Bool
    @Binding var password: String
    @Binding var privateKeyContent: String
    @Binding var privateKeyPassphrase: String

    var body: some View {
        AddServerSectionCard(title: "跳板机（可选）") {
            Toggle("通过 SSH 跳板机连接此资产", isOn: $isEnabled)
                .toggleStyle(.switch)

            if isEnabled {
                Text("先验证并登录跳板机，再从跳板机建立到目标资产的加密通道。两台服务器的主机密钥和凭据会独立校验。")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)

                AddServerFormRow(icon: "point.3.connected.trianglepath.dotted", title: "跳板地址") {
                    AddServerTextField("例如：bastion.example.com", text: $host)
                }
                AddServerFormRow(icon: "number", title: "跳板端口") {
                    AddServerTextField("默认 22", text: $portText, numeric: true)
                }
                AddServerFormRow(icon: "person.fill", title: "跳板用户名") {
                    AddServerTextField("例如：ops", text: $username)
                }
                AddServerFormRow(icon: "lock.shield.fill", title: "跳板认证") {
                    Picker("跳板认证", selection: $authMethod) {
                        ForEach(ServerAuthMethod.allCases) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                AddServerFormRow(icon: "lock.fill", title: "跳板密码") {
                    AddServerSecureField("可选：SSH 密码", text: $password)
                }
                AddServerFormRow(icon: "key.fill", title: "跳板私钥") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextEditor(text: $privateKeyContent)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 92, maxHeight: 132)
                            .padding(6)
                            .foregroundStyle(palette.textPrimary.color)
                            .background(palette.surfaceInput.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(palette.borderGlass.color))
                        Text("跳板私钥仅保存到系统钥匙串；可使用 OPENSSH 或 PEM 格式。")
                            .font(.caption2)
                            .foregroundStyle(palette.textSecondary.color)
                    }
                }
                AddServerFormRow(icon: "key.radiowaves.forward", title: "私钥口令") {
                    AddServerSecureField("可选：用于解密跳板私钥", text: $privateKeyPassphrase)
                }
                AddServerFormRow(icon: "shield.lefthalf.filled", title: "跳板策略") {
                    Toggle(
                        "仅允许跳板私钥登录",
                        isOn: Binding(
                            get: { !allowPasswordFallback },
                            set: { allowPasswordFallback = !$0 }
                        )
                    )
                    .toggleStyle(.switch)
                }

                if !allowPasswordFallback {
                    Text("已开启仅密钥模式：跳板连接将跳过密码认证。")
                        .font(.caption)
                        .foregroundStyle(security.warning.color)
                }
            }
        }
    }
}
