#if os(macOS)
import SwiftUI

struct RemoteDesktopWorkspaceView: View {
    @ObservedObject var controller: RemoteDesktopSessionController

    var body: some View {
        ZStack {
            Color.black
            if let engine = controller.engineSession {
                FreeRDPDesktopSurface(model: engine.frameBuffer, engineSession: engine)
            }
            statusOverlay
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topTrailing) {
            controls
                .padding(12)
        }
        .alert(item: $controller.certificateChallenge) { challenge in
            Alert(
                title: Text(challenge.changed ? "远程桌面证书已变化" : "确认远程桌面证书"),
                message: Text(certificateMessage(challenge)),
                primaryButton: .default(Text("继续本次连接"), action: controller.acceptCertificateOnce),
                secondaryButton: .cancel(Text("取消"), action: controller.rejectCertificate)
            )
        }
        .accessibilityLabel("远程桌面工作区")
        .accessibilityValue(controller.phase.rawValue)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch controller.phase {
        case .starting, .authenticating, .reconnecting:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(statusText)
                    .foregroundStyle(.white)
            }
            .padding(22)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        case .failed, .disconnected:
            if let message = controller.failureMessage {
                VStack(spacing: 12) {
                    Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                        .font(.title)
                    Text(message).multilineTextAlignment(.center)
                    Button("重新连接") { Task { await controller.reconnect() } }
                }
                .foregroundStyle(.white)
                .padding(22)
                .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12))
            }
        default:
            EmptyView()
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { Task { await controller.reconnect() } } label: {
                Label("重新连接", systemImage: "arrow.clockwise")
            }
            Button(action: controller.toggleFullScreen) {
                Label("全屏", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
        .buttonStyle(.borderedProminent)
        .labelStyle(.iconOnly)
        .help("远程桌面会话控制")
    }

    private var statusText: String {
        switch controller.phase {
        case .starting: "正在准备远程桌面…"
        case .authenticating: "正在验证凭据并协商 NLA…"
        case .reconnecting: "正在重新连接并适配窗口尺寸…"
        default: "正在连接…"
        }
    }

    private func certificateMessage(_ challenge: RemoteDesktopCertificateChallenge) -> String {
        let identity = challenge.commonName.isEmpty ? challenge.host : challenge.commonName
        let issuer = challenge.issuer.isEmpty ? "未知签发者" : challenge.issuer
        let fingerprint = challenge.fingerprint.isEmpty ? "未提供" : challenge.fingerprint
        return "目标：\(identity):\(challenge.port)\n签发者：\(issuer)\n指纹：\(fingerprint)\n\n仅在确认目标身份后继续。本次接受不会自动信任今后的证书变化。"
    }
}
#endif
