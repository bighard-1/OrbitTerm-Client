import SwiftUI

struct TelnetRiskConfirmationView: View {
    let route: TelnetRiskPresentationRoute
    let onCancel: () -> Void
    let onConnect: () -> Void

    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("确认明文 Telnet 连接", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.orange)

            Text("Telnet 不提供加密或服务器身份验证。用户名、密码、命令和终端内容可能被同一网络中的其他设备读取或篡改。")

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("目标").foregroundStyle(.secondary)
                    Text(route.displayName)
                }
                GridRow {
                    Text("地址").foregroundStyle(.secondary)
                    Text(route.endpoint).font(.system(.body, design: .monospaced))
                }
            }
            .textSelection(.enabled)

            Toggle("我确认这是隔离内网或 VPN 内的受信旧设备，并了解明文传输风险", isOn: $acknowledged)
                .toggleStyle(.switch)

            Text("此确认仅适用于当前目标和地址。目标地址变化、关闭 Telnet 或重新安装应用后需要重新确认。SSH 连接不会自动回退到 Telnet。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("取消", role: .cancel, action: onCancel)
                Spacer()
                Button("仍要连接", role: .destructive, action: onConnect)
                    .buttonStyle(.borderedProminent)
                    .disabled(!acknowledged)
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.orange, lineWidth: 1)
        )
        .padding()
        .accessibilityElement(children: .contain)
    }
}
