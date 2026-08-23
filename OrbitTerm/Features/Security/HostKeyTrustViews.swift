import SwiftUI

struct HostKeyTrustView: View {
    @ObservedObject var coordinator: HostKeyTrustCoordinator
    private let copyText: (String) -> Void
    private let onCancel: () -> Void
    private let onTrust: () -> Void
    private let onRetrySave: () -> Void
    private let onClose: () -> Void

    init(
        coordinator: HostKeyTrustCoordinator,
        copyText: @escaping (String) -> Void = { text in
            Task { @MainActor in
                _ = SecureClipboard.copy(text, kind: .hostKeyFingerprint)
            }
        },
        onCancel: (() -> Void)? = nil,
        onTrust: (() -> Void)? = nil,
        onRetrySave: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.copyText = copyText
        self.onCancel = onCancel ?? coordinator.cancel
        self.onTrust = onTrust ?? { Task { await coordinator.trustCurrentChallenge() } }
        self.onRetrySave = onRetrySave ?? { Task { await coordinator.retrySave() } }
        self.onClose = onClose ?? coordinator.close
    }

    var body: some View {
        Group {
            switch coordinator.state {
            case .idle:
                EmptyView()
            case .connecting, .reconnecting:
                progressView("正在验证服务器身份")
            case let .awaitingUserDecision(_, challenge):
                HostKeyChallengeSheet(
                    presentation: HostKeyChallengePresentation(payload: challenge),
                    onCancel: onCancel,
                    onTrust: onTrust
                )
            case let .persisting(_, challenge, _):
                HostKeyChallengeSheet(
                    presentation: HostKeyChallengePresentation(
                        payload: challenge,
                        isPersisting: true
                    ),
                    onCancel: onCancel,
                    onTrust: {}
                )
            case .connected:
                EmptyView()
            case let .blocked(_, block):
                HostKeyBlockedView(
                    presentation: HostKeyBlockedPresentation(payload: block),
                    onClose: onClose,
                    onCopy: copyText
                )
            case .failed(_, .storeSave):
                HostKeySaveErrorView(
                    presentation: HostKeySaveErrorPresentation(),
                    onRetry: onRetrySave,
                    onCancel: onCancel
                )
            case .failed:
                HostKeyFailureView(onClose: onClose)
            case .cancelled:
                EmptyView()
            }
        }
    }

    private func progressView(_ title: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(title).font(.headline)
        }
        .padding(24)
    }
}

struct HostKeyChallengeSheet: View {
    let presentation: HostKeyChallengePresentation
    let onCancel: () -> Void
    let onTrust: () -> Void

    var body: some View {
        HostKeyCard {
            Label("验证服务器身份", systemImage: "key.horizontal.fill")
                .font(.title2.weight(.semibold))
            Text("这是 OrbitTerm 首次看到此服务器密钥。请先核对指纹，再决定是否信任。")
            HostKeyFingerprintView(
                host: presentation.host,
                port: presentation.port,
                algorithm: presentation.algorithm,
                fingerprints: [("SHA256", presentation.fingerprint)]
            )
            HStack {
                Button("取消", action: onCancel)
                Spacer()
                Button("信任此服务器", action: onTrust)
                    .buttonStyle(.borderedProminent)
                    .disabled(presentation.isPersisting || presentation.isExpired)
            }
            if presentation.isExpired {
                Label(
                    "此验证请求已过期。请关闭此窗口后重新发起连接。",
                    systemImage: "clock.badge.exclamationmark"
                )
                .foregroundStyle(.secondary)
            }
            if presentation.isPersisting {
                ProgressView("正在保存信任信息…")
            }
        }
    }
}

struct HostKeyBlockedView: View {
    let presentation: HostKeyBlockedPresentation
    let onClose: () -> Void
    let onCopy: (String) -> Void

    var body: some View {
        HostKeyCard(isWarning: true) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
            Text(message)
            HostKeyFingerprintView(
                host: presentation.host,
                port: presentation.port,
                algorithm: presentation.algorithm,
                fingerprints: fingerprintRows
            )
            HStack {
                Button("关闭", action: onClose)
                Spacer()
                Button("复制指纹") { onCopy(presentation.copyText) }
            }
        }
    }

    private var title: String {
        switch presentation.severity {
        case .changed: "服务器身份已变更"
        case .revoked: "服务器密钥已撤销"
        case .unsupported: "服务器密钥已阻断"
        }
    }

    private var message: String {
        switch presentation.severity {
        case .changed:
            "服务器提供了不同的密钥。在通过独立渠道核实变更前，连接将保持阻断。"
        case .revoked:
            "此服务器密钥已被撤销。OrbitTerm 不会继续连接。"
        case .unsupported:
            "此服务器密钥无法被安全验证。OrbitTerm 不会继续连接。"
        }
    }

    private var fingerprintRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let previous = presentation.previousFingerprint {
            rows.append(("原指纹", previous))
        }
        rows.append(("当前指纹", presentation.presentedFingerprint))
        return rows
    }
}

struct HostKeySaveErrorView: View {
    let presentation: HostKeySaveErrorPresentation
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HostKeyCard(isWarning: true) {
            Label(presentation.title, systemImage: "externaldrive.badge.exclamationmark")
                .font(.title2.weight(.semibold))
            Text(presentation.message)
            HStack {
                Button("取消", action: onCancel)
                Spacer()
                Button("重新保存", action: onRetry)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct HostKeyFingerprintView: View {
    let host: String
    let port: UInt16
    let algorithm: String
    let fingerprints: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            row("主机", "\(host):\(port)")
            row("算法", algorithm)
            ForEach(Array(fingerprints.enumerated()), id: \.offset) { _, item in
                row(item.0, item.1, monospaced: true)
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HostKeyCard<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let isWarning: Bool
    @ViewBuilder let content: Content

    init(isWarning: Bool = false, @ViewBuilder content: () -> Content) {
        self.isWarning = isWarning
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(isWarning ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(
                        isWarning ? Color.orange : Color.secondary,
                        lineWidth: contrast == .increased ? 2 : 1
                    )
            )
            .padding()
    }
}

private struct HostKeyFailureView: View {
    let onClose: () -> Void

    var body: some View {
        HostKeyCard(isWarning: true) {
            Label("连接无法继续", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
            Text("OrbitTerm 在打开会话前已安全停止。请检查连接信息后重试。")
            Button("关闭", action: onClose)
        }
    }
}
