import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Notification.Name {
    /// Sensitive editors subscribe to this event and wipe only transient user
    /// input. Persisted credentials remain in Keychain and are never touched.
    static let orbitTermClearTransientSensitiveInput = Notification.Name("orbitterm.clear-transient-sensitive-input")
}

/// The separately signed iOS QA app can bypass covers for capture states that
/// iOS reports. This is not an iPhone Mirroring detector or opt-out: on some
/// device/OS combinations, Mirroring may leave public capture signals inactive.
/// Release builds and the normal app bundle never compile or pass this bypass.
enum MirroredCaptureQAMode {
    static var isEnabled: Bool {
#if os(iOS) && DEBUG && ORBITTERM_IOS_MIRROR_QA
        Bundle.main.bundleIdentifier == "com.orbitterm.matrix.ios"
#else
        false
#endif
    }
}

@MainActor
final class SensitiveScreenProtection: ObservableObject {
    static let shared = SensitiveScreenProtection()

    @Published private(set) var isScreenCaptured = false
    private var observers: [NSObjectProtocol] = []

    private init() {
#if canImport(UIKit)
        isScreenCaptured = UIScreen.main.isCaptured
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIScreen.capturedDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.isScreenCaptured = UIScreen.main.isCaptured
                    if UIScreen.main.isCaptured && !MirroredCaptureQAMode.isEnabled {
                        NotificationCenter.default.post(name: .orbitTermClearTransientSensitiveInput, object: nil)
                    }
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.userDidTakeScreenshotNotification,
                object: nil,
                queue: .main
            ) { _ in
                // iOS offers no supported way to block a user-initiated
                // screenshot. Wipe transient secrets immediately afterwards
                // so they cannot remain exposed when the app is revisited.
                NotificationCenter.default.post(
                    name: .orbitTermClearTransientSensitiveInput,
                    object: nil
                )
            }
        )
#endif
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

private struct SensitiveContentCover: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 34, weight: .semibold))
                Text("OrbitTerm 已保护敏感内容")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("敏感内容已隐藏")
        }
        .ignoresSafeArea()
    }
}

#if os(macOS)
private struct SensitiveWindowConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSView) {
        DispatchQueue.main.async {
            // Prevent this window from being exposed through the window-sharing
            // APIs. The in-app inactive cover protects the app-switch preview.
            view.window?.sharingType = .none
        }
    }
}
#endif

private struct SensitiveScreenProtectionModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
#if os(iOS)
    @Environment(\.isSceneCaptured) private var isSceneCaptured
#endif
    @StateObject private var protection = SensitiveScreenProtection.shared
    @StateObject private var clipboardNotice = ClipboardSecurityNotice.shared

    private var isCaptureActive: Bool {
#if os(iOS)
        // Combine the scene-level and legacy screen-level signals. Neither is
        // guaranteed to report every iPhone Mirroring session on real devices.
        (isSceneCaptured || protection.isScreenCaptured) && !MirroredCaptureQAMode.isEnabled
#else
        protection.isScreenCaptured
#endif
    }

    func body(content: Content) -> some View {
        content
#if os(macOS)
            .background(SensitiveWindowConfiguration().frame(width: 0, height: 0))
#endif
            .overlay {
                if SensitiveScreenVisibilityPolicy.shouldCover(
                    isSceneActive: scenePhase == .active,
                    isScreenCaptured: isCaptureActive
                ) {
                    SensitiveContentCover()
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if let message = clipboardNotice.message,
                   scenePhase == .active,
                   !isCaptureActive {
                    Text(message)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.84), in: Capsule())
                        .padding(.bottom, 18)
                        .accessibilityLabel(message)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase != .active else { return }
                NotificationCenter.default.post(name: .orbitTermClearTransientSensitiveInput, object: nil)
            }
            .onChange(of: isCaptureActive) { _, captured in
                guard captured else { return }
                NotificationCenter.default.post(name: .orbitTermClearTransientSensitiveInput, object: nil)
            }
    }
}

extension View {
    /// Hides app content in inactive states and reported capture sessions.
    /// Public capture signals can remain inactive during iPhone Mirroring, so
    /// this modifier alone does not guarantee that mirrored content is hidden.
    /// iOS has no public API to block a user-initiated screenshot while the app
    /// is active; sensitive input is secure/ephemeral and is wiped on capture.
    @ViewBuilder
    func protectSensitiveScreenContent(enabled: Bool = true) -> some View {
        if enabled {
            modifier(SensitiveScreenProtectionModifier())
        } else {
            self
        }
    }
}
