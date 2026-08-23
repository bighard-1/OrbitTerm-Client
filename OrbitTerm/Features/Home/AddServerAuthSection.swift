import SwiftUI

struct AddServerAuthSection: View {
    @Environment(\.appThemePalette) private var palette
    @Environment(\.securitySemanticPalette) private var security
    @Binding var username: String
    @Binding var authMethod: ServerAuthMethod
    @Binding var transport: ServerTransportProtocol
    @Binding var networkDeviceProfile: NetworkDeviceProfile
    @Binding var password: String
    @Binding var keyInputMode: KeyInputMode
    @Binding var privateKeyContent: String
    @Binding var privateKeyPassphrase: String
    @Binding var allowPasswordFallback: Bool

    let telnetEnabled: Bool
    let selectedKeyFileName: String
    let privateKeyValidationMessage: String
    let privateKeyValidationKind: SecurityStatusKind?
    let onSelectKeyFile: () -> Void

    var body: some View {
        AddServerSectionCard(title: "认证") {
            AddServerFormRow(icon: "person.fill", title: "用户名") {
                AddServerTextField("例如：root", text: $username)
            }

            AddServerFormRow(icon: "switch.2", title: "认证方式") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("认证方式", selection: $authMethod) {
                        ForEach(ServerAuthMethod.allCases) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(transport == .telnet)

                    if transport == .telnet {
                        Text("Telnet 使用文本提示符自动登录，认证方式固定为密码。")
                            .font(.caption2)
                            .foregroundStyle(palette.textSecondary.color)
                    }
                }
            }

            AddServerFormRow(icon: "network", title: "传输协议") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("传输协议", selection: $transport) {
                        ForEach(availableTransports) { proto in
                            Text(proto.displayName).tag(proto)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    if !telnetEnabled {
                        Text("Telnet 默认关闭。可在“设置 > 终端与连接”了解风险并手动启用；关闭状态下无法保存或连接 Telnet 资产。")
                            .font(.caption2)
                            .foregroundStyle(palette.textSecondary.color)
                    }
                }
            }

            if transport == .telnet {
                telnetProfileSection
            }

            AddServerFormRow(icon: "lock.fill", title: "密码") {
                AddServerSecureField(transport == .telnet ? "用于自动应答 Password 提示" : "可选：SSH 密码", text: $password)
            }

            if transport == .ssh {
                sshCredentialOptions
            } else {
                Text("Telnet 密码仅存储在系统钥匙串，连接时用于自动应答设备登录提示符。")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary.color)
            }
        }
    }

    private var availableTransports: [ServerTransportProtocol] {
        if telnetEnabled || transport == .telnet {
            return ServerTransportProtocol.allCases
        }
        return [.ssh]
    }

    private var telnetProfileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            AddServerFormRow(icon: "switch.2", title: "设备模板") {
                Picker("设备模板", selection: $networkDeviceProfile) {
                    ForEach(NetworkDeviceProfile.allCases) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .labelsHidden()
            }

            Text("Telnet 无加密或服务器身份验证。OrbitTerm 会根据模板识别 Username/Password 等提示符并自动应答。")
                .font(.caption)
                .foregroundStyle(security.warning.color)
        }
    }

    private var sshCredentialOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            AddServerFormRow(icon: "switch.2", title: "密钥输入") {
                Picker("密钥输入", selection: $keyInputMode) {
                    ForEach(KeyInputMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            AddServerFormRow(icon: "key.fill", title: "私钥内容") {
                VStack(alignment: .leading, spacing: 8) {
                    if keyInputMode == .file {
                        Button(action: onSelectKeyFile) {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.badge.plus")
                                Text(selectedKeyFileName.isEmpty ? "选择私钥文件" : selectedKeyFileName)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(ThemedSecondaryButtonStyle())
                    }

                    TextEditor(text: $privateKeyContent)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120, maxHeight: 180)
                        .padding(6)
                        .foregroundStyle(palette.textPrimary.color)
                        .background(palette.surfaceInput.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(palette.borderGlass.color))

                    Text(privateKeyValidationMessage)
                        .font(.caption)
                        .foregroundStyle(privateKeyValidationKind.map { security.presentation(for: $0).color.color } ?? palette.textSecondary.color)
                }
            }

            AddServerFormRow(icon: "lock.shield.fill", title: "私钥口令") {
                AddServerSecureField("可选：用于解密受保护私钥", text: $privateKeyPassphrase)
            }

            AddServerFormRow(icon: "shield.lefthalf.filled", title: "登录策略") {
                Toggle(
                    "仅允许密钥登录",
                    isOn: Binding(
                        get: { !allowPasswordFallback },
                        set: { allowPasswordFallback = !$0 }
                    )
                )
                .toggleStyle(.switch)
            }

            if !allowPasswordFallback {
                Text("已开启仅密钥模式：连接时将强制跳过密码认证。")
                    .font(.caption)
                    .foregroundStyle(security.warning.color)
            }

            Text("支持 OPENSSH/PEM 私钥。密码、私钥内容与口令仅存储在系统钥匙串。")
                .font(.caption)
                .foregroundStyle(palette.textSecondary.color)
        }
    }
}
