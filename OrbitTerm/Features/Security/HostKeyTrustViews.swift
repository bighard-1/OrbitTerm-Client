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
        copyText: @escaping (String) -> Void = { _ in },
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
                progressView("Verifying Server Identity")
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
            Label("Verify Server Identity", systemImage: "key.horizontal.fill")
                .font(.title2.weight(.semibold))
            Text("This is the first time OrbitTerm has seen this server key. Verify the fingerprint before continuing.")
            HostKeyFingerprintView(
                host: presentation.host,
                port: presentation.port,
                algorithm: presentation.algorithm,
                fingerprints: [("SHA256", presentation.fingerprint)]
            )
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Trust This Host", action: onTrust)
                    .buttonStyle(.borderedProminent)
                    .disabled(presentation.isPersisting || presentation.isExpired)
            }
            if presentation.isExpired {
                Label(
                    "This verification request has expired. Close this dialog and start again.",
                    systemImage: "clock.badge.exclamationmark"
                )
                .foregroundStyle(.secondary)
            }
            if presentation.isPersisting {
                ProgressView("Saving trust…")
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
                Button("Close", action: onClose)
                Spacer()
                Button("Copy Fingerprints") { onCopy(presentation.copyText) }
            }
        }
    }

    private var title: String {
        switch presentation.severity {
        case .changed: "Server Identity Changed"
        case .revoked: "Server Key Revoked"
        case .unsupported: "Server Key Blocked"
        }
    }

    private var message: String {
        switch presentation.severity {
        case .changed:
            "The server presented a different key. Connection is blocked until the change is verified outside OrbitTerm."
        case .revoked:
            "This server key has been revoked. OrbitTerm will not continue the connection."
        case .unsupported:
            "This server key cannot be safely verified. OrbitTerm will not continue the connection."
        }
    }

    private var fingerprintRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let previous = presentation.previousFingerprint {
            rows.append(("Previous", previous))
        }
        rows.append(("Presented", presentation.presentedFingerprint))
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
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Retry Save", action: onRetry)
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
            row("Host", "\(host):\(port)")
            row("Algorithm", algorithm)
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
            Label("Connection Couldn’t Continue", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
            Text("OrbitTerm stopped before opening the session. Try again after reviewing the connection details.")
            Button("Close", action: onClose)
        }
    }
}
