import SwiftUI
import UniformTypeIdentifiers

private enum ConnectionKeyInputMode: String, CaseIterable, Identifiable {
    case paste
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste: return "粘贴字符串"
        case .file: return "选择文件"
        }
    }
}

struct ConnectionView: View {
    @StateObject private var manager = OrbitManager()

    @State private var ip = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod: ServerAuthMethod = .password
    @State private var allowPasswordFallback = true

    @State private var password = ""
    @State private var privateKeyContent = ""
    @State private var privateKeyPassphrase = ""
    @State private var keyInputMode: ConnectionKeyInputMode = .paste
    @State private var showKeyFileImporter = false
    @State private var selectedKeyFileName = ""

    var body: some View {
        Form {
            Section("连接信息") {
                TextField("IP 地址（例如 192.168.1.10）", text: $ip)
                    .applyInputPolish()
#if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
#endif

                TextField("用户名", text: $username)
                    .applyInputPolish()
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif

                TextField("端口", text: $port)
                    .applyInputPolish()
#if os(iOS)
                    .keyboardType(.numberPad)
#endif

                Picker("认证方式", selection: $authMethod) {
                    ForEach(ServerAuthMethod.allCases) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .pickerStyle(.segmented)

                SecureField("密码（可选）", text: $password)
                    .applyInputPolish()

                Picker("密钥输入", selection: $keyInputMode) {
                    ForEach(ConnectionKeyInputMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if keyInputMode == .file {
                    Button {
                        showKeyFileImporter = true
                    } label: {
                        HStack {
                            Image(systemName: "doc.badge.plus")
                            Text(selectedKeyFileName.isEmpty ? "选择私钥文件" : selectedKeyFileName)
                                .lineLimit(1)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $privateKeyContent)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Text(privateKeyValidationMessage)
                        .font(.caption)
                        .foregroundStyle(privateKeyValidationColor)
                }

                SecureField("私钥口令（可选）", text: $privateKeyPassphrase)
                    .applyInputPolish()

                Toggle(
                    "仅允许密钥登录",
                    isOn: Binding(
                        get: { !allowPasswordFallback },
                        set: { allowPasswordFallback = !$0 }
                    )
                )
            }

            Section("操作") {
                Button("测试连接") {
                    manager.testConnection(
                        ip: ip.trimmingCharacters(in: .whitespacesAndNewlines),
                        port: parsedPort,
                        username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                        password: password,
                        privateKeyContent: privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines),
                        privateKeyPassphrase: privateKeyPassphrase,
                        allowPasswordFallback: allowPasswordFallback
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canTest)
            }

            Section("连接状态") {
                HStack {
                    Text("状态")
                    Spacer()
                    Text(manager.statusText)
                        .foregroundStyle(statusColor(manager.statusText))
                }
            }
        }
        .navigationTitle("连接测试")
        .fileImporter(
            isPresented: $showKeyFileImporter,
            allowedContentTypes: [.data, .plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            guard keyInputMode == .file else { return }
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                selectedKeyFileName = url.lastPathComponent
                loadPrivateKeyFile(url)
            case let .failure(error):
                manager.statusText = "失败: 私钥文件读取失败 - \(error.localizedDescription)"
            }
        }
    }

    private var canTest: Bool {
        let hasBase = !ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (1...65535).contains(parsedPort)
        guard hasBase else { return false }

        if !allowPasswordFallback {
            return hasValidPrivateKey
        }

        switch authMethod {
        case .password:
            return !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasValidPrivateKey
        case .key:
            return hasValidPrivateKey || !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var isPrivateKeyFormatValid: Bool {
        let key = privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        let pattern = #"(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*-----END [A-Z0-9 ]*PRIVATE KEY-----"#
        return key.range(of: pattern, options: .regularExpression) != nil
    }

    private var parsedPort: Int {
        Int(port) ?? 22
    }

    private var hasValidPrivateKey: Bool {
        let key = privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return !key.isEmpty && isPrivateKeyFormatValid
    }

    private var privateKeyValidationMessage: String {
        if privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "未提供私钥（可选）"
        }
        return isPrivateKeyFormatValid ? "私钥格式校验通过" : "私钥格式不合法，需包含 BEGIN/END PRIVATE KEY"
    }

    private var privateKeyValidationColor: Color {
        let key = privateKeyContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            return .secondary
        }
        return isPrivateKeyFormatValid ? .green : .red
    }

    private func statusColor(_ status: String) -> Color {
        if status.hasPrefix("成功") {
            return .green
        }
        if status.hasPrefix("失败") {
            return .red
        }
        if status.contains("连接中") {
            return .orange
        }
        return .secondary
    }

    private func loadPrivateKeyFile(_ url: URL) {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url)
            guard let key = String(data: data, encoding: .utf8) else {
                manager.statusText = "失败: 私钥文件不是 UTF-8 文本"
                return
            }
            privateKeyContent = key
        } catch {
            manager.statusText = "失败: 私钥文件读取失败 - \(error.localizedDescription)"
        }
    }
}
