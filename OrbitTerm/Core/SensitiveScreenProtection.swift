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

#if os(iOS)
/// Read the UIKit trait on a view in the actual window scene. This is a
/// second supported observation path alongside SwiftUI's scene environment;
/// a global screen object can miss scene-scoped capture transitions.
@MainActor
private final class SceneCaptureTraitView: UIView {
    var onCaptureChange: ((UISceneCaptureState) -> Void)?
    private var traitRegistration: (any UITraitChangeRegistration)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        traitRegistration = registerForTraitChanges([UITraitSceneCaptureState.self]) {
            (view: SceneCaptureTraitView, _) in
            view.reportCaptureState()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("SceneCaptureTraitView is created programmatically")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportCaptureState()
    }

    private func reportCaptureState() {
        onCaptureChange?(traitCollection.sceneCaptureState)
    }
}

private struct SceneCaptureTraitReader: UIViewRepresentable {
    let onChange: (UISceneCaptureState) -> Void

    func makeUIView(context: Context) -> SceneCaptureTraitView {
        let view = SceneCaptureTraitView(frame: .zero)
        view.onCaptureChange = onChange
        return view
    }

    func updateUIView(_ view: SceneCaptureTraitView, context: Context) {
        view.onCaptureChange = onChange
    }
}

/// This opt-in is intentionally memory-only. A process restart, account
/// change, lock, background transition or the deadline restores protection.
@MainActor
final class TemporaryCaptureAuthorization: ObservableObject {
    static let shared = TemporaryCaptureAuthorization()

    @Published private(set) var expiresAt: Date?
    private var authorizedAccount: String?
    private var capturedSources = Set<UUID>()
    private var expirationTask: Task<Void, Never>?
    private var generation = UUID()

    private init() {}

    func updateReportedCapture(_ reported: Bool, source: UUID) {
        if reported {
            capturedSources.insert(source)
        } else {
            capturedSources.remove(source)
        }
    }

    func removeCaptureObserver(_ source: UUID) {
        capturedSources.remove(source)
    }

    @discardableResult
    func authorize(for account: String, now: Date = Date()) -> Bool {
        guard !account.isEmpty, capturedSources.isEmpty else { return false }
        revoke()
        authorizedAccount = account
        expiresAt = now.addingTimeInterval(TemporaryCaptureAuthorizationPolicy.lifetime)
        let currentGeneration = generation
        expirationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            guard !Task.isCancelled, self?.generation == currentGeneration else { return }
            self?.revoke()
        }
        return true
    }

    func revoke() {
        generation = UUID()
        expirationTask?.cancel()
        expirationTask = nil
        authorizedAccount = nil
        expiresAt = nil
    }

    func allowsCapture(
        account: String,
        now: Date = Date(),
        isAuthenticated: Bool,
        isUnlocked: Bool,
        mustChangePassword: Bool,
        isSceneActive: Bool
    ) -> Bool {
        TemporaryCaptureAuthorizationPolicy.allows(
            authorizedAccount: authorizedAccount,
            currentAccount: account,
            expiresAt: expiresAt,
            now: now,
            isAuthenticated: isAuthenticated,
            isUnlocked: isUnlocked,
            mustChangePassword: mustChangePassword,
            isSceneActive: isSceneActive
        )
    }
}

/// UIKit takes the app-switcher snapshot during deactivation, before SwiftUI
/// is guaranteed to render a scenePhase-driven cover. Install this opaque
/// view synchronously at willResignActive, then remove it on activation.
@MainActor
private final class InactiveSnapshotShield: NSObject {
    private var covers: [ObjectIdentifier: UIView] = [:]

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func willResignActive() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where !window.isHidden {
                let key = ObjectIdentifier(window)
                guard covers[key] == nil else { continue }
                let cover = UIView(frame: window.bounds)
                cover.backgroundColor = .black
                cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                cover.isUserInteractionEnabled = false
                window.addSubview(cover)
                covers[key] = cover
            }
        }
    }

    @objc private func didBecomeActive() {
        // Let the normal app-lock view settle before uncovering the window.
        DispatchQueue.main.async { [weak self] in
            self?.covers.values.forEach { $0.removeFromSuperview() }
            self?.covers.removeAll()
        }
    }
}
#endif

@MainActor
final class SensitiveScreenProtection: ObservableObject {
    static let shared = SensitiveScreenProtection()

    @Published private(set) var isScreenCaptured = false
    private var observers: [NSObjectProtocol] = []
#if os(iOS)
    private let inactiveSnapshotShield = InactiveSnapshotShield()
#endif

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
    @EnvironmentObject private var session: AppSession
    @State private var nativeSceneCaptureState: UISceneCaptureState = .unspecified
    @State private var captureObserverID = UUID()
    @StateObject private var temporaryCapture = TemporaryCaptureAuthorization.shared
#endif
    @StateObject private var protection = SensitiveScreenProtection.shared
    @StateObject private var clipboardNotice = ClipboardSecurityNotice.shared

    private var isCaptureActive: Bool {
#if os(iOS)
        // Combine the scene-level and legacy screen-level signals. Neither is
        // guaranteed to report every iPhone Mirroring session on real devices.
        SensitiveCaptureSignalPolicy.isCaptured(
            swiftUIScene: isSceneCaptured,
            uiKitScene: nativeSceneCaptureState == .active,
            screen: protection.isScreenCaptured,
            qaBypass: MirroredCaptureQAMode.isEnabled
        )
#else
        protection.isScreenCaptured
#endif
    }

#if os(iOS)
    private var isCaptureReported: Bool {
        isSceneCaptured || nativeSceneCaptureState == .active || protection.isScreenCaptured
    }

    private var allowsTemporaryCapture: Bool {
        temporaryCapture.allowsCapture(
            account: session.username,
            isAuthenticated: session.isAuthenticated,
            isUnlocked: session.isUnlocked,
            mustChangePassword: session.mustChangePassword,
            isSceneActive: scenePhase == .active
        )
    }
#else
    private var allowsTemporaryCapture: Bool { false }
#endif

    func body(content: Content) -> some View {
        content
#if os(iOS)
            .background(
                SceneCaptureTraitReader { state in
                    nativeSceneCaptureState = state
                }
                .frame(width: 0, height: 0)
            )
#endif
#if os(macOS)
            .background(SensitiveWindowConfiguration().frame(width: 0, height: 0))
#endif
            .overlay {
                if SensitiveScreenVisibilityPolicy.shouldCover(
                    isSceneActive: scenePhase == .active,
                    isScreenCaptured: isCaptureActive,
                    allowsTemporaryCapture: allowsTemporaryCapture
                ) {
                    SensitiveContentCover()
                        // App-switcher snapshots may be captured before an
                        // opacity transition finishes. Cover immediately.
                        .transition(.identity)
                }
            }
#if os(iOS)
            .overlay(alignment: .top) {
                if allowsTemporaryCapture, let expiresAt = temporaryCapture.expiresAt {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle")
                        Text("临时允许录屏")
                        Text(expiresAt, style: .timer)
                        Button("停止") { temporaryCapture.revoke() }
                            .fontWeight(.semibold)
                    }
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.92), in: Capsule())
                    .padding(.top, 8)
                    .accessibilityElement(children: .contain)
                }
            }
#endif
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
#if os(iOS)
                // Control Center can make the scene merely inactive while the
                // user starts recording. Keep the grant but keep the opaque
                // cover until the scene is active again. A real background
                // transition still revokes it.
                if phase == .background { temporaryCapture.revoke() }
#endif
                NotificationCenter.default.post(name: .orbitTermClearTransientSensitiveInput, object: nil)
            }
            .onChange(of: isCaptureActive) { _, captured in
                guard captured else { return }
                NotificationCenter.default.post(name: .orbitTermClearTransientSensitiveInput, object: nil)
            }
#if os(iOS)
            .onAppear {
                temporaryCapture.updateReportedCapture(isCaptureReported, source: captureObserverID)
            }
            .onDisappear {
                temporaryCapture.removeCaptureObserver(captureObserverID)
            }
            .onChange(of: isCaptureReported) { _, reported in
                temporaryCapture.updateReportedCapture(reported, source: captureObserverID)
            }
            .onChange(of: session.isUnlocked) { _, unlocked in
                if !unlocked { temporaryCapture.revoke() }
            }
            .onChange(of: session.isAuthenticated) { _, authenticated in
                if !authenticated { temporaryCapture.revoke() }
            }
            .onChange(of: session.username) { _, _ in
                temporaryCapture.revoke()
            }
            .onChange(of: session.mustChangePassword) { _, required in
                if required { temporaryCapture.revoke() }
            }
#endif
#if os(iOS) && ORBITTERM_CAPTURE_DIAGNOSTIC_QA
            .overlay(alignment: .top) {
                if Bundle.main.bundleIdentifier == "com.orbitterm.matrix.ios" {
                    Text("QA capture scene=\(isSceneCaptured ? 1 : 0) trait=\(nativeSceneCaptureState.rawValue) screen=\(protection.isScreenCaptured ? 1 : 0)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black)
                }
            }
#endif
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
