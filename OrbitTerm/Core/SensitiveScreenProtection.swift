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

/// A SwiftUI overlay attached to ContentView sits *behind* system sheets.
/// Keep an opaque, window-level shield above every app presentation while a
/// reported capture is not authorized. This also covers sheets opened before
/// a three-minute authorization expires.
@MainActor
private final class CaptureWindowShield: NSObject {
    static let shared = CaptureWindowShield()

    private var covers: [ObjectIdentifier: UIView] = [:]
    private var isCovered = false

    override private init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowBecameVisible),
            name: UIWindow.didBecomeVisibleNotification,
            object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func setCovered(_ covered: Bool) {
        isCovered = covered
        guard covered else {
            covers.values.forEach { $0.removeFromSuperview() }
            covers.removeAll()
            return
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where !window.isHidden {
                install(on: window)
            }
        }
    }

    @objc private func windowBecameVisible(_ notification: Notification) {
        guard isCovered, let window = notification.object as? UIWindow else { return }
        install(on: window)
    }

    private func install(on window: UIWindow) {
        let key = ObjectIdentifier(window)
        if let cover = covers[key], cover.superview === window {
            window.bringSubviewToFront(cover)
            return
        }

        let cover = UIView(frame: window.bounds)
        cover.backgroundColor = .black
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.isUserInteractionEnabled = true
        cover.isAccessibilityElement = true
        cover.accessibilityViewIsModal = true
        cover.accessibilityLabel = "OrbitTerm 已保护敏感内容。检测到录屏或共享；请先停止录制，再解锁应用并重新开启临时授权。"

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "lock.shield.fill"))
        icon.tintColor = .white
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
        let title = UILabel()
        title.text = "OrbitTerm 已保护敏感内容"
        title.textColor = .white
        title.font = .preferredFont(forTextStyle: .headline)
        title.textAlignment = .center
        let detail = UILabel()
        detail.text = "检测到录屏或共享。请先停止录制，再解锁应用并重新开启临时授权。"
        detail.textColor = .white
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.textAlignment = .center
        detail.numberOfLines = 0
        for view in [icon, title, detail] { stack.addArrangedSubview(view) }
        cover.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: cover.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cover.trailingAnchor, constant: -28),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 320)
        ])

        window.addSubview(cover)
        covers[key] = cover
    }
}

#if !ORBITTERM_PUBLIC_RELEASE
/// Exercises the real window shield over a presented sheet using synthetic,
/// non-account UI-test content. Never included in public Release builds.
@MainActor
enum CaptureWindowShieldUITestHook {
    static func coverPresentedWindow() {
        CaptureWindowShield.shared.setCovered(true)
    }
}
#endif

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
        refreshWindowShield()
    }

    func removeCaptureObserver(_ source: UUID) {
        capturedSources.remove(source)
        refreshWindowShield()
    }

    @discardableResult
    func authorize(for account: String, now: Date = Date()) -> Bool {
        guard !account.isEmpty, !isCaptureReported else { return false }
        revoke()
        authorizedAccount = account
        expiresAt = now.addingTimeInterval(TemporaryCaptureAuthorizationPolicy.lifetime)
        refreshWindowShield()
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
        // Install the window shield before publishing the settings UI's
        // expired/blue state; otherwise a presented sheet could draw one
        // exposed frame while SwiftUI reacts to the deadline.
        refreshWindowShield()
        expiresAt = nil
    }

    private var isCaptureReported: Bool {
        let reportedByScene = UIApplication.shared.connectedScenes.contains { scene in
            (scene as? UIWindowScene)?.traitCollection.sceneCaptureState == .active
        }
        return !capturedSources.isEmpty || UIScreen.main.isCaptured || reportedByScene
    }

    private func refreshWindowShield(now: Date = Date()) {
        let hasLiveGrant = authorizedAccount != nil && expiresAt.map { now < $0 } == true
        CaptureWindowShield.shared.setCovered(isCaptureReported && !hasLiveGrant && !MirroredCaptureQAMode.isEnabled)
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

#if ORBITTERM_CAPTURE_DIAGNOSTIC_QA
/// Only compiled into an explicitly flagged, separately identified QA app.
/// Records state transitions, never screen content, identifiers or secrets.
@MainActor
final class CaptureQADiagnostics: ObservableObject {
    static let shared = CaptureQADiagnostics()

    @Published private(set) var entries: [String] = []

    private init() {}

    func record(
        _ event: String,
        scenePhase: ScenePhase,
        captured: Bool,
        grantExists: Bool,
        grantAllows: Bool,
        unlocked: Bool
    ) {
        guard Bundle.main.bundleIdentifier == "com.orbitterm.matrix.ios" else { return }
        let state = UIApplication.shared.applicationState.rawValue
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        let sample = "\(timestamp) \(event) scene=\(scenePhase) app=\(state) cap=\(captured ? 1 : 0) grant=\(grantExists ? 1 : 0) allow=\(grantAllows ? 1 : 0) unlock=\(unlocked ? 1 : 0)"
        entries.append(sample)
        if entries.count > 12 { entries.removeFirst(entries.count - 12) }
    }
}
#endif

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
    var captureRecoveryMessage: String? = nil

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 34, weight: .semibold))
                Text("OrbitTerm 已保护敏感内容")
                    .font(.headline)
                if let captureRecoveryMessage {
                    Text(captureRecoveryMessage)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
            }
            .foregroundStyle(.white)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(captureRecoveryMessage.map { "敏感内容已隐藏。\($0)" } ?? "敏感内容已隐藏")
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

    private var captureRecoveryMessage: String? {
        guard scenePhase == .active, isCaptureActive, !allowsTemporaryCapture else { return nil }
        return "检测到录屏或共享。请先停止录制，再解锁应用并重新开启临时授权；离开应用后授权会自动失效。"
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
    private var captureRecoveryMessage: String? { nil }
    private var allowsTemporaryCapture: Bool { false }
#endif

#if os(iOS) && ORBITTERM_CAPTURE_DIAGNOSTIC_QA
    private func recordCaptureQASample(_ event: String) {
        CaptureQADiagnostics.shared.record(
            event,
            scenePhase: scenePhase,
            captured: isCaptureReported,
            grantExists: temporaryCapture.expiresAt != nil,
            grantAllows: allowsTemporaryCapture,
            unlocked: session.isUnlocked
        )
    }
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
                    SensitiveContentCover(captureRecoveryMessage: captureRecoveryMessage)
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
                if phase != .active {
#if os(iOS)
                    // Control Center may make the scene merely inactive while
                    // recording starts. Keep the grant, but cover the scene.
                    if phase == .background { temporaryCapture.revoke() }
#endif
                    NotificationCenter.default.post(name: .orbitTermClearTransientSensitiveInput, object: nil)
                }
#if os(iOS) && ORBITTERM_CAPTURE_DIAGNOSTIC_QA
                recordCaptureQASample("scene")
#endif
            }
            .onChange(of: isCaptureActive) { _, captured in
                guard captured else { return }
                NotificationCenter.default.post(name: .orbitTermClearTransientSensitiveInput, object: nil)
            }
#if os(iOS)
            .onAppear {
                temporaryCapture.updateReportedCapture(isCaptureReported, source: captureObserverID)
#if ORBITTERM_CAPTURE_DIAGNOSTIC_QA
                recordCaptureQASample("appear")
#endif
            }
            .onDisappear {
                temporaryCapture.removeCaptureObserver(captureObserverID)
            }
            .onChange(of: isCaptureReported) { _, reported in
                temporaryCapture.updateReportedCapture(reported, source: captureObserverID)
#if ORBITTERM_CAPTURE_DIAGNOSTIC_QA
                recordCaptureQASample("capture")
#endif
            }
            .onChange(of: session.isUnlocked) { _, unlocked in
                if !unlocked { temporaryCapture.revoke() }
#if ORBITTERM_CAPTURE_DIAGNOSTIC_QA
                recordCaptureQASample("unlock")
#endif
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
#if ORBITTERM_CAPTURE_DIAGNOSTIC_QA
            .onChange(of: temporaryCapture.expiresAt) { _, _ in
                recordCaptureQASample("grant")
            }
#endif
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
