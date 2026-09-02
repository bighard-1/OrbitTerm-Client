import Foundation
import Combine
import Network

enum LocalStorageFailureKind: Equatable {
    case secureStorageUnavailable
    case protectedDataInvalid
    case databaseCorrupted
    case storageFull
    case databaseUnavailable
    case migrationInterrupted
}

struct LocalStorageRecoveryPresentation: Equatable {
    let kind: LocalStorageFailureKind
    let title: String
    let message: String
    let actionLabel: String
}

enum LocalStorageRecoveryPolicy {
    static func keychainFailure(_ error: KeychainManager.KeychainError) -> LocalStorageRecoveryPresentation {
        switch error {
        case let .unhandled(status):
            return presentation(for: keychainFailureKind(status: status))
        case .invalidData:
            return presentation(for: .protectedDataInvalid)
        }
    }

    static func keychainFailureKind(status: OSStatus) -> LocalStorageFailureKind {
        // Missing entitlement, interaction-not-allowed and service-not-
        // available are all recoverable access failures. Item-not-found is
        // handled by KeychainDataStore as a valid signed-out state.
        switch status {
        case -34018, -25308, -25291:
            return .secureStorageUnavailable
        default:
            return .secureStorageUnavailable
        }
    }

    static func sqliteFailureKind(code: Int32) -> LocalStorageFailureKind {
        switch code & 0xff {
        case 11: return .databaseCorrupted // SQLITE_CORRUPT
        case 13: return .storageFull // SQLITE_FULL
        case 10, 14: return .databaseUnavailable // SQLITE_IOERR / SQLITE_CANTOPEN
        default: return .databaseUnavailable
        }
    }

    static func presentation(for kind: LocalStorageFailureKind) -> LocalStorageRecoveryPresentation {
        switch kind {
        case .secureStorageUnavailable:
            return .init(
                kind: kind,
                title: "暂时无法访问安全存储",
                message: "系统钥匙串中的登录状态当前无法验证。OrbitTerm 不会将此情况视为退出登录，也不会覆盖现有凭据。",
                actionLabel: "重新检查"
            )
        case .protectedDataInvalid:
            return .init(
                kind: kind,
                title: "安全存储数据需要处理",
                message: "系统钥匙串返回的数据无法安全解析。OrbitTerm 已停止继续写入，不会自动删除或重建凭据。",
                actionLabel: "重新检查"
            )
        case .databaseCorrupted:
            return .init(
                kind: kind,
                title: "本地数据库需要处理",
                message: "检测到本地同步队列完整性异常。同步已暂停，现有队列不会被自动删除。",
                actionLabel: "重新检查"
            )
        case .storageFull:
            return .init(
                kind: kind,
                title: "设备存储空间不足",
                message: "本地同步操作无法安全提交。请释放存储空间后重试，未发送的操作不会被清除。",
                actionLabel: "重新检查"
            )
        case .databaseUnavailable:
            return .init(
                kind: kind,
                title: "暂时无法访问本地同步队列",
                message: "云端变更已暂停提交，OrbitTerm 不会绕过持久化队列直接发送或删除现有数据。",
                actionLabel: "重新检查"
            )
        case .migrationInterrupted:
            return .init(
                kind: kind,
                title: "本地数据升级未完成",
                message: "本地数据升级未能安全提交。写入已暂停，现有数据不会被自动重建或删除。",
                actionLabel: "重新检查"
            )
        }
    }
}

@MainActor
final class LocalStorageIssueCenter: ObservableObject {
    static let shared = LocalStorageIssueCenter()

    @Published private(set) var syncQueueIssue: LocalStorageRecoveryPresentation?

    private init() {}

    func reportSyncQueueFailure(code: Int32) {
        syncQueueIssue = LocalStorageRecoveryPolicy.presentation(
            for: LocalStorageRecoveryPolicy.sqliteFailureKind(code: code)
        )
    }

    func clearSyncQueueFailure() {
        syncQueueIssue = nil
    }
}

/// Lifecycle events that may change the ownership of account-scoped work.
/// They deliberately describe application policy rather than platform APIs so
/// the rules remain testable without a SwiftUI scene or live connection.
enum ApplicationOperationLifecycleEvent: Equatable {
    case becameActive
    case becameInactive
    case enteredBackground
    case accountLocked
    case accountSignedOut
    case mainWindowClosed
    case applicationTerminating
}

enum ApplicationOperationQueueDisposition: Equatable {
    case resume
    case suspend
}

struct ApplicationOperationLifecycleDirective: Equatable {
    let syncQueue: ApplicationOperationQueueDisposition
    let auxiliaryRefreshesActive: Bool
    let closeSessions: Bool
    let clearTransientSensitiveInput: Bool
}

/// Product-level lifecycle contract:
/// - an inactive app pauses refresh work but does not tear down a macOS user’s
///   visible workspace merely because focus changed;
/// - iOS backgrounding pauses application-owned refreshes. The operating
///   system may later suspend or close a socket; OrbitTerm never promises a
///   persistent background SSH connection. A configured master-password lock
///   then follows the existing account-lock teardown path;
/// - locking, signing out, or explicitly terminating the application closes
///   sessions, so no invisible SSH/SFTP/Docker/Monitor work survives without
///   an unlocked account owner;
/// - closing a macOS window is intentionally different from quitting: it
///   pauses visible auxiliary work but leaves the independently-owned session
///   lifecycle untouched. This preserves a workspace when macOS keeps the app
///   alive after its last window is closed;
/// - only an active, authenticated, unlocked account may resume background
///   work.
enum ApplicationOperationLifecyclePolicy {
    static func directive(
        for event: ApplicationOperationLifecycleEvent,
        isAuthenticated: Bool,
        isUnlocked: Bool
    ) -> ApplicationOperationLifecycleDirective {
        switch event {
        case .accountLocked, .accountSignedOut, .applicationTerminating:
            return ApplicationOperationLifecycleDirective(
                syncQueue: .suspend,
                auxiliaryRefreshesActive: false,
                closeSessions: true,
                clearTransientSensitiveInput: true
            )
        case .becameInactive, .enteredBackground, .mainWindowClosed:
            return ApplicationOperationLifecycleDirective(
                syncQueue: .suspend,
                auxiliaryRefreshesActive: false,
                closeSessions: false,
                clearTransientSensitiveInput: true
            )
        case .becameActive:
            let canResume = isAuthenticated && isUnlocked
            return ApplicationOperationLifecycleDirective(
                syncQueue: canResume ? .resume : .suspend,
                auxiliaryRefreshesActive: canResume,
                closeSessions: false,
                clearTransientSensitiveInput: !canResume
            )
        }
    }
}

enum MobileAutoLockPolicy {
    static func shouldLockOnBackground(
        isAuthenticated: Bool,
        hasMasterPassword: Bool
    ) -> Bool {
        isAuthenticated && hasMasterPassword
    }
}

enum SessionReconnectAvailability: Equatable {
    case available
    case waitingForNetwork
    case reconnecting
}

enum SessionReconnectPolicy {
    static func availability(isNetworkUsable: Bool, reconnecting: Bool) -> SessionReconnectAvailability {
        if reconnecting { return .reconnecting }
        return isNetworkUsable ? .available : .waitingForNetwork
    }

    static func canReconnect(isNetworkUsable: Bool, reconnecting: Bool) -> Bool {
        availability(isNetworkUsable: isNetworkUsable, reconnecting: reconnecting) == .available
    }

    static func accessibilityLabel(isNetworkUsable: Bool, reconnecting: Bool) -> String {
        switch availability(isNetworkUsable: isNetworkUsable, reconnecting: reconnecting) {
        case .available: "重新连接当前会话"
        case .waitingForNetwork: "等待网络恢复后重新连接"
        case .reconnecting: "正在重新连接当前会话"
        }
    }
}

/// Session routing deliberately accepts satisfied local-only paths. Requiring
/// Apple's equivalent of public-internet validation would incorrectly disable
/// SSH to isolated Wi-Fi and Ethernet targets.
@MainActor
final class ApplicationNetworkAvailability: ObservableObject {
    static let shared = ApplicationNetworkAvailability()

    // Fail closed until NWPathMonitor publishes its first real route. This may
    // disable the button for a brief launch interval, but never starts a
    // connection from an assumed-online state.
    @Published private(set) var isNetworkUsable = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.orbitterm.session-network")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let usable = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isNetworkUsable = usable
            }
        }
        monitor.start(queue: queue)
    }
}

/// Persists one non-sensitive bit so a newly launched process can explain why
/// native SSH/Telnet handles were intentionally not reconstructed.
struct LiveSessionRecoveryMarker {
    private let defaults: UserDefaults
    private let key = "orbitterm.live-sessions-present.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func consumeInterruptedProcessMarker() -> Bool {
        let wasPresent = defaults.bool(forKey: key)
        defaults.removeObject(forKey: key)
        return wasPresent
    }

    func markLiveSessionsPresent() {
        defaults.set(true, forKey: key)
    }

    func clearLiveSessions() {
        defaults.removeObject(forKey: key)
    }
}
