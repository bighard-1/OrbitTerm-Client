import SwiftUI

struct ConnectionView: View {
    @StateObject private var manager = OrbitManager()
    @State private var ip: String = ""
    @State private var username: String = ""
    @State private var password: String = ""

    var body: some View {
        Form {
            Section("连接信息") {
                TextField("IP 地址（例如 192.168.1.10）", text: $ip)
                    .applyInputPolish()
                TextField("用户名", text: $username)
                    .applyInputPolish()
                SecureField("密码", text: $password)
            }

            Section("操作") {
                Button("测试连接") {
                    manager.testConnection(ip: ip, username: username, password: password)
                }
                .buttonStyle(.borderedProminent)
                .disabled(ip.isEmpty || username.isEmpty || password.isEmpty)
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
}
