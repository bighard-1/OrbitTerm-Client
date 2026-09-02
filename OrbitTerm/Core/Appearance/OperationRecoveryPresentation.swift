import Foundation

enum SyncPresentationPhase: Equatable {
    case idle, awaitingNetwork, awaitingUnlock, syncing, succeeded, failed
}

struct SyncPresentationState: Equatable {
    let phase: SyncPresentationPhase
    let headline: String
    let detail: String

    static let idle = make(.idle, detail: "尚未开始同步")

    static func make(_ phase: SyncPresentationPhase, detail: String) -> SyncPresentationState {
        let headline: String = switch phase {
        case .idle: "等待同步"
        case .awaitingNetwork: "等待网络"
        case .awaitingUnlock: "等待解锁"
        case .syncing: "同步中"
        case .succeeded: "同步完成"
        case .failed: "同步失败"
        }
        return SyncPresentationState(phase: phase, headline: headline, detail: detail)
    }

    static func afterCompletedPull(
        detail: String,
        auxiliaryFailureDetails: [String]
    ) -> SyncPresentationState {
        guard !auxiliaryFailureDetails.isEmpty else {
            return make(.succeeded, detail: detail)
        }
        return make(
            .failed,
            detail: "资产已同步；" + auxiliaryFailureDetails.joined(separator: "；")
        )
    }
}

enum SyncConflictPresentation {
    static let title = "检测到同步冲突"
    static let keepLocalLabel = "保留本地修改"
    static let keepCloudLabel = "保留云端修改"
    static let localSectionTitle = "本地修改"
    static let cloudSectionTitle = "云端修改"
}

enum SecurityOperationFeedbackKind: Equatable {
    case success
    case failure
    case recoveryRequired
}

enum BiometricLifecycleFailure: Equatable {
    case cancelled
    case lockedOut
    case unavailable
    case invalidated
    case failed
}

enum BiometricAuthenticationOutcome: Equatable {
    case success
    case failure(BiometricLifecycleFailure)
}

struct SecurityOperationFeedback: Equatable {
    let kind: SecurityOperationFeedbackKind
    let message: String

    var isFailure: Bool { kind != .success }

    var autoDismissAfterNanoseconds: UInt64? {
        OperationalFeedbackPolicy.lifetime(
            kind: kind == .success ? .success : .failure
        ).autoDismissAfterNanoseconds
    }
}

enum SecurityOperationPresentation {
    static let loginPasswordSuccess = "已更新登录密码；其他设备需要重新登录。"
    static let masterPasswordSuccess = "已完成主密码轮换；其他设备需要重新登录并使用新主密码解锁。"
    static let localCommitSuccess = "已完成本地主密码更新。"
    static let loginPasswordBusy = "正在更新登录密码…"
    static let masterPasswordBusy = "正在轮换主密码…"
    static let logoutTitle = "退出登录？"
    static let logoutMessage = "将断开当前所有会话并清除当前登录状态；本机加密数据仍按账户隔离保留。"
    static let logoutConfirm = "退出登录"
    static let biometricEnabledSuccess = "已启用生物识别解锁。"
    static let biometricDisabledSuccess = "已关闭生物识别解锁。"
    static let biometricUnlockSuccess = "已通过生物识别解锁。"
    static let biometricInvalidated = "生物识别密钥已失效，请使用主密码解锁后重新启用。"
    static let biometricLockedOut = "生物识别暂时锁定，请使用主密码解锁。"
    static let biometricUnavailable = "此设备未配置可用的强生物识别方式。"
    static let biometricFailed = "生物识别未通过，请重试或使用主密码解锁。"
    static let biometricBusy = "正在验证…"

    static func biometricFailure(_ failure: BiometricLifecycleFailure) -> SecurityOperationFeedback? {
        switch failure {
        case .cancelled:
            return nil
        case .lockedOut:
            return .init(kind: .failure, message: biometricLockedOut)
        case .unavailable:
            return .init(kind: .recoveryRequired, message: biometricUnavailable)
        case .invalidated:
            return .init(kind: .recoveryRequired, message: biometricInvalidated)
        case .failed:
            return .init(kind: .failure, message: biometricFailed)
        }
    }
}

enum RecentlyDeletedPresentationPhase: Equatable {
    case loading, empty, ready, failed
}

struct RecentlyDeletedPresentation: Equatable {
    let phase: RecentlyDeletedPresentationPhase
    let headline: String
    let detail: String
    let refreshLabel: String
    let refreshEnabled: Bool
    let staleContentMessage: String?
}

enum RecentlyDeletedPresentationMapper {
    static func make(
        isLoading: Bool,
        itemCount: Int,
        failureDetail: String?,
        isMutating: Bool
    ) -> RecentlyDeletedPresentation {
        let hasItems = itemCount > 0
        if isLoading {
            return RecentlyDeletedPresentation(
                phase: .loading,
                headline: hasItems ? "正在刷新最近删除" : "正在读取最近删除",
                detail: hasItems ? "当前记录仍可查看" : "正在安全读取删除记录",
                refreshLabel: "刷新中…",
                refreshEnabled: false,
                staleContentMessage: nil
            )
        }
        if let failureDetail {
            return RecentlyDeletedPresentation(
                phase: .failed,
                headline: "无法加载最近删除",
                detail: failureDetail,
                refreshLabel: "重试",
                refreshEnabled: !isMutating,
                staleContentMessage: hasItems ? "操作未完成，当前删除记录仍可查看。" : nil
            )
        }
        if !hasItems {
            return RecentlyDeletedPresentation(
                phase: .empty,
                headline: "最近删除为空",
                detail: "删除的云端资产会在保留期内显示在这里",
                refreshLabel: "刷新",
                refreshEnabled: !isMutating,
                staleContentMessage: nil
            )
        }
        return RecentlyDeletedPresentation(
            phase: .ready,
            headline: "最近删除",
            detail: "共 \(itemCount) 条删除记录",
            refreshLabel: "刷新",
            refreshEnabled: !isMutating,
            staleContentMessage: nil
        )
    }

    static func successMessage(action: String, queued: Bool) -> String {
        queued ? "\(action)已加入后台队列，联网后自动完成。" : "资产已\(action)。"
    }
}

/// The bounded set of user-recoverable failure categories shared by every
/// client operation.  This intentionally does not carry an `Error`, URL,
/// host, command, path, request ID, or raw FFI payload.
enum OperationFailureDomain: String, Equatable, Sendable {
    case sync
    case sftp
    case docker
    case monitor
    case connection
}

enum OperationFailureCode: String, Equatable, Sendable {
    case authenticationExpired
    case authenticationFailed
    case masterPasswordLocked
    case masterPasswordMismatch
    case networkUnavailable
    case timedOut
    case serviceConfigurationInvalid
    case serviceUnavailable
    case requestRejected
    case verifiedSessionRequired
    case sessionClosed
    case hostIdentityBlocked
    case terminalOpenFailed
    case localSecureStorageFailed
    case operationCancelled
    case protocolViolation
    case unsupportedOperation
    case unknown
}

enum OperationRecoveryAction: String, Hashable, Sendable {
    case retry
    case reconnect
    case reauthenticate
    case unlock
    case reviewHostKey
    case reviewCredentials
    case reviewServiceConfiguration
    case dismiss
}

enum OperationFailureSeverity: Equatable, Sendable {
    case warning
    case danger
}

/// A small transport classification kept separate from any HTTP client so the
/// presentation model remains independently testable.
enum SyncRecoveryNetworkFailure: Equatable, Sendable {
    case authenticationExpired
    case serviceConfigurationInvalid
    case serviceUnavailable
    case requestRejected
    case protocolViolation
    case timedOut
    case networkUnavailable
    case unknown
}

/// Lets transport implementations expose only a redacted recovery category
/// without making the independently tested presentation layer depend on a
/// concrete HTTP client type.
protocol SyncRecoveryClassifiable: Error {
    var syncRecoveryFailure: SyncRecoveryNetworkFailure { get }
}

/// Read-only, redacted presentation data. Views decide how to perform an
/// allowed action; this type never owns a service or triggers business work.
struct OperationRecoveryPresentation: Equatable, Sendable {
    let domain: OperationFailureDomain
    let code: OperationFailureCode
    let title: String
    let message: String
    let systemImage: String
    let severity: OperationFailureSeverity
    let actions: Set<OperationRecoveryAction>

    /// Safe for diagnostics and support export. It contains no operation
    /// payload or user-identifying value.
    var diagnosticCode: String {
        "\(domain.rawValue).\(code.rawValue)"
    }
}

enum OperationRecoveryMapper {
    static func sync(_ failure: SyncRecoveryNetworkFailure) -> OperationRecoveryPresentation {
        switch failure {
        case .authenticationExpired:
            return presentation(
                domain: .sync,
                code: .authenticationExpired,
                title: "登录已失效",
                message: "请重新登录后再同步。",
                symbol: "person.crop.circle.badge.exclamationmark",
                severity: .warning,
                actions: [.reauthenticate]
            )
        case .serviceConfigurationInvalid:
            return presentation(
                domain: .sync,
                code: .serviceConfigurationInvalid,
                title: "同步服务设置无效",
                message: "请检查服务设置后重试。",
                symbol: "gearshape.badge.exclamationmark",
                severity: .warning,
                actions: [.reviewServiceConfiguration, .dismiss]
            )
        case .serviceUnavailable:
            return presentation(
                domain: .sync,
                code: .serviceUnavailable,
                title: "同步服务暂不可用",
                message: "本地数据已保留，可稍后重试。",
                symbol: "icloud.slash",
                severity: .warning,
                actions: [.retry, .dismiss]
            )
        case .requestRejected:
            return presentation(
                domain: .sync,
                code: .requestRejected,
                title: "同步请求被拒绝",
                message: "本地数据已保留，请检查服务版本或配置后处理受阻项目。",
                symbol: "exclamationmark.octagon.fill",
                severity: .danger,
                actions: [.reviewServiceConfiguration, .dismiss]
            )
        case .protocolViolation:
            return presentation(
                domain: .sync,
                code: .protocolViolation,
                title: "同步响应无效",
                message: "本地数据已保留，请稍后重试。",
                symbol: "exclamationmark.triangle.fill",
                severity: .danger,
                actions: [.retry, .dismiss]
            )
        case .timedOut:
            return transport(domain: .sync, timedOut: true)
        case .networkUnavailable:
            return transport(domain: .sync, timedOut: false)
        case .unknown:
            return presentation(
                domain: .sync,
                code: .unknown,
                title: "同步未完成",
                message: "本地数据已保留，请稍后重试。",
                symbol: "arrow.triangle.2.circlepath.circle",
                severity: .warning,
                actions: [.retry, .dismiss]
            )
        }
    }

    static func syncTokenUnavailable() -> OperationRecoveryPresentation {
        presentation(
            domain: .sync,
            code: .authenticationExpired,
            title: "登录令牌不可用",
            message: "请重新登录后再同步。",
            symbol: "person.crop.circle.badge.exclamationmark",
            severity: .warning,
            actions: [.reauthenticate]
        )
    }

    static func syncMasterPasswordUnavailable() -> OperationRecoveryPresentation {
        presentation(
            domain: .sync,
            code: .masterPasswordLocked,
            title: "主密码未解锁",
            message: "请解锁主密码后再同步。",
            symbol: "lock.fill",
            severity: .warning,
            actions: [.unlock, .dismiss]
        )
    }

    static func syncMasterPasswordMismatch() -> OperationRecoveryPresentation {
        presentation(
            domain: .sync,
            code: .masterPasswordMismatch,
            title: "无法解密云端资产",
            message: "请确认设备使用相同的主密码后重试。",
            symbol: "key.fill",
            severity: .danger,
            actions: [.unlock, .retry, .dismiss]
        )
    }

    static func sftp(_ error: CheckedSFTPServiceError) -> OperationRecoveryPresentation {
        switch error {
        case .requiresVerifiedSession, .legacySFTPDisabledInCheckedMode:
            return verifiedSessionRequired(domain: .sftp)
        case .sessionClosed:
            return sessionClosed(domain: .sftp)
        case .userCancelled:
            return cancelled(domain: .sftp)
        case .checkedSFTPOpenFailed:
            return transport(domain: .sftp, timedOut: false)
        case .requestIDMismatch, .unexpectedKind, .unknownCheckedFFIError,
             .invalidSFTPSessionID, .internalInvariant:
            return protocolFailure(domain: .sftp)
        }
    }

    static func docker(_ error: CheckedDockerServiceError) -> OperationRecoveryPresentation {
        switch error {
        case .requiresVerifiedSession, .legacyDockerDisabledInCheckedMode:
            return verifiedSessionRequired(domain: .docker)
        case .sessionClosed:
            return sessionClosed(domain: .docker)
        case .refreshCancelled:
            return cancelled(domain: .docker)
        case .renameUpdateDisabledInCheckedMode, .invalidContainerID, .invalidDockerAction:
            return presentation(
                domain: .docker,
                code: .unsupportedOperation,
                title: "Docker 操作不可用",
                message: "请检查当前容器状态后重试。",
                symbol: "shippingbox.fill",
                severity: .warning,
                actions: [.dismiss]
            )
        case .checkedDockerOperationFailed:
            return transport(domain: .docker, timedOut: false)
        case .requestIDMismatch, .unexpectedKind, .unknownCheckedFFIError,
             .invalidBaseSessionID, .internalInvariant:
            return protocolFailure(domain: .docker)
        }
    }

    static func monitor(_ error: CheckedMonitorServiceError) -> OperationRecoveryPresentation {
        switch error {
        case .requiresVerifiedSession, .legacyMonitorDisabledInCheckedMode:
            return verifiedSessionRequired(domain: .monitor)
        case .sessionClosed:
            return sessionClosed(domain: .monitor)
        case .pollingCancelled:
            return cancelled(domain: .monitor)
        case .checkedMonitorSnapshotFailed:
            return transport(domain: .monitor, timedOut: false)
        case .requestIDMismatch, .unexpectedKind, .unknownCheckedFFIError,
             .invalidBaseSessionID, .internalInvariant:
            return protocolFailure(domain: .monitor)
        }
    }

    static func connection(_ outcome: CheckedTerminalConnectionOutcome) -> OperationRecoveryPresentation? {
        switch outcome {
        case .pending, .awaitingUserDecision, .connected:
            return nil
        case .cancelled:
            return cancelled(domain: .connection)
        case .blocked:
            return presentation(
                domain: .connection,
                code: .hostIdentityBlocked,
                title: "服务器身份已阻断",
                message: "为保护连接安全，未建立会话。请核对主机密钥。",
                symbol: "xmark.shield.fill",
                severity: .danger,
                actions: [.reviewHostKey, .dismiss]
            )
        case .terminalOpenFailed:
            return presentation(
                domain: .connection,
                code: .terminalOpenFailed,
                title: "终端未能打开",
                message: "安全连接已停止，请重新连接。",
                symbol: "terminal.fill",
                severity: .warning,
                actions: [.reconnect, .dismiss]
            )
        case let .failed(failure):
            return connection(failure)
        }
    }

    static func connection(_ failure: HostKeyTrustFailure) -> OperationRecoveryPresentation {
        switch failure {
        case .authentication:
            return presentation(
                domain: .connection,
                code: .authenticationFailed,
                title: "认证失败",
                message: "请检查凭据后重新连接。",
                symbol: "person.crop.circle.badge.exclamationmark",
                severity: .warning,
                actions: [.reviewCredentials, .reconnect, .dismiss]
            )
        case .network:
            return transport(domain: .connection, timedOut: false)
        case .timeout:
            return transport(domain: .connection, timedOut: true)
        case .store, .storeSave:
            return presentation(
                domain: .connection,
                code: .localSecureStorageFailed,
                title: "无法保存主机信任信息",
                message: "未建立连接，请检查系统钥匙串权限后重试。",
                symbol: "key.fill",
                severity: .danger,
                actions: [.retry, .dismiss]
            )
        case .operation, .client, .protocolViolation:
            return protocolFailure(domain: .connection)
        }
    }

    private static func verifiedSessionRequired(domain: OperationFailureDomain) -> OperationRecoveryPresentation {
        presentation(
            domain: domain,
            code: .verifiedSessionRequired,
            title: "需要已验证的 SSH 会话",
            message: "请先完成服务器身份确认并建立连接。",
            symbol: "checkmark.shield.fill",
            severity: .warning,
            actions: [.reconnect, .dismiss]
        )
    }

    private static func sessionClosed(domain: OperationFailureDomain) -> OperationRecoveryPresentation {
        presentation(
            domain: domain,
            code: .sessionClosed,
            title: "会话已关闭",
            message: "请重新连接后再继续操作。",
            symbol: "network.slash",
            severity: .warning,
            actions: [.reconnect, .dismiss]
        )
    }

    private static func cancelled(domain: OperationFailureDomain) -> OperationRecoveryPresentation {
        presentation(
            domain: domain,
            code: .operationCancelled,
            title: "操作已取消",
            message: "未执行额外更改。",
            symbol: "xmark.circle",
            severity: .warning,
            actions: [.dismiss]
        )
    }

    private static func protocolFailure(domain: OperationFailureDomain) -> OperationRecoveryPresentation {
        presentation(
            domain: domain,
            code: .protocolViolation,
            title: "安全响应无效",
            message: "操作已停止，请重新连接后重试。",
            symbol: "exclamationmark.triangle.fill",
            severity: .danger,
            actions: [.reconnect, .dismiss]
        )
    }

    private static func transport(
        domain: OperationFailureDomain,
        timedOut: Bool
    ) -> OperationRecoveryPresentation {
        presentation(
            domain: domain,
            code: timedOut ? .timedOut : .networkUnavailable,
            title: timedOut ? "操作超时" : "网络暂不可用",
            message: timedOut ? "请检查网络后重试。" : "请恢复网络后重试。",
            symbol: timedOut ? "clock.badge.exclamationmark" : "wifi.exclamationmark",
            severity: .warning,
            actions: [.retry, .dismiss]
        )
    }

    private static func presentation(
        domain: OperationFailureDomain,
        code: OperationFailureCode,
        title: String,
        message: String,
        symbol: String,
        severity: OperationFailureSeverity,
        actions: Set<OperationRecoveryAction>
    ) -> OperationRecoveryPresentation {
        OperationRecoveryPresentation(
            domain: domain,
            code: code,
            title: title,
            message: message,
            systemImage: symbol,
            severity: severity,
            actions: actions
        )
    }
}

extension OperationRecoveryMapper {
    /// Converts transport errors without retaining URLs, response bodies or
    /// account identifiers in presentation state.
    static func sync(_ error: Error) -> OperationRecoveryPresentation {
        if let classified = error as? SyncRecoveryClassifiable {
            return sync(classified.syncRecoveryFailure)
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled {
                return cancelled(domain: .sync)
            }
            return sync(urlError.code == .timedOut ? .timedOut : .networkUnavailable)
        }
        if error is CancellationError {
            return cancelled(domain: .sync)
        }
        return sync(.unknown)
    }
}

enum LoginCooldownPolicy {
    static func seconds(failureCount: Int) -> Int {
        switch failureCount {
        case ..<3: return 0
        case 3: return 5
        case 4: return 15
        case 5: return 30
        case 6: return 60
        case 7: return 120
        default: return 300
        }
    }
}

enum OperationalContentPhase: String, Equatable {
    case loading
    case empty
    case paused
    case failed
    case ready
}

enum OperationalModuleKind: Equatable {
    case monitor
    case sftp
    case docker
}

struct OperationalContentPresentation: Equatable {
    let phase: OperationalContentPhase
    let headline: String
    let detail: String
}

struct OperationalActionPresentation: Equatable {
    let refreshLabel: String
    let refreshAccessibilityLabel: String
    let refreshEnabled: Bool
    let showsRefreshProgress: Bool
    let staleContentMessage: String?
}

enum OperationalFeedbackKind: Equatable {
    case success
    case failure
}

struct OperationalFeedbackLifetime: Equatable {
    let autoDismissAfterNanoseconds: UInt64?
}

enum OperationalFeedbackPolicy {
    static let successVisibleNanoseconds: UInt64 = 4_000_000_000

    static func lifetime(kind: OperationalFeedbackKind) -> OperationalFeedbackLifetime {
        .init(
            autoDismissAfterNanoseconds: kind == .success
                ? successVisibleNanoseconds
                : nil
        )
    }
}

enum OperationalContentPresentationMapper {
    static func monitor(
        isLoading: Bool,
        hasData: Bool,
        isPolling: Bool,
        failureDetail: String?
    ) -> OperationalContentPresentation {
        if let failureDetail {
            return .init(phase: .failed, headline: "监控读取失败", detail: failureDetail)
        }
        if !isPolling {
            return .init(phase: .paused, headline: "采样已暂停", detail: "开始采样后将继续更新系统指标。")
        }
        if isLoading && !hasData {
            return .init(phase: .loading, headline: "正在加载监控", detail: "正在通过当前已验证 SSH 会话采样。")
        }
        if !hasData {
            return .init(phase: .empty, headline: "暂无监控数据", detail: "采样完成后，CPU、内存、磁盘与网络信息会显示在这里。")
        }
        return .init(phase: .ready, headline: "监控中", detail: "系统指标会按设定间隔持续更新。")
    }

    static func sftp(
        isLoading: Bool,
        hasItems: Bool,
        failureDetail: String?
    ) -> OperationalContentPresentation {
        if let failureDetail {
            return .init(phase: .failed, headline: "SFTP 操作失败", detail: failureDetail)
        }
        if isLoading && !hasItems {
            return .init(phase: .loading, headline: "正在加载目录", detail: "正在通过当前已验证 SSH 会话读取目录。")
        }
        if !hasItems {
            return .init(phase: .empty, headline: "此目录为空", detail: "可在此目录新建文件、目录或上传文件。")
        }
        return .init(phase: .ready, headline: "目录已就绪", detail: "可浏览或管理当前目录内容。")
    }

    static func docker(
        isLoading: Bool,
        hasContainers: Bool,
        failureDetail: String?
    ) -> OperationalContentPresentation {
        if let failureDetail {
            return .init(phase: .failed, headline: "Docker 操作失败", detail: failureDetail)
        }
        if isLoading && !hasContainers {
            return .init(phase: .loading, headline: "正在加载容器", detail: "正在通过当前已验证 SSH 会话读取容器状态。")
        }
        if !hasContainers {
            return .init(phase: .empty, headline: "暂无容器", detail: "当前已连接服务器没有可管理的 Docker 容器。")
        }
        return .init(phase: .ready, headline: "容器已就绪", detail: "可查看状态、日志并执行容器操作。")
    }

    static func refreshAction(
        module: OperationalModuleKind,
        phase: OperationalContentPhase,
        isRefreshing: Bool,
        hasContent: Bool
    ) -> OperationalActionPresentation {
        let moduleLabel: String
        switch module {
        case .monitor: moduleLabel = "监控"
        case .sftp: moduleLabel = "目录"
        case .docker: moduleLabel = "容器"
        }
        let isRetry = phase == .failed
        let staleContentMessage: String?
        if isRetry && hasContent {
            switch module {
            case .monitor: staleContentMessage = "操作未完成，正在显示上次成功的监控数据。"
            case .sftp: staleContentMessage = "操作未完成，当前目录列表仍可查看。"
            case .docker: staleContentMessage = "操作未完成，正在显示上次成功的容器列表。"
            }
        } else {
            staleContentMessage = nil
        }
        return .init(
            refreshLabel: isRefreshing ? "刷新中…" : (isRetry ? "重试" : "刷新"),
            refreshAccessibilityLabel: isRefreshing ? "正在刷新\(moduleLabel)" : (isRetry ? "重试刷新\(moduleLabel)" : "刷新\(moduleLabel)"),
            refreshEnabled: !isRefreshing,
            showsRefreshProgress: isRefreshing,
            staleContentMessage: staleContentMessage
        )
    }

    static func monitorSamplingLabel(isPolling: Bool) -> String {
        isPolling ? "暂停采样" : "恢复采样"
    }
}
