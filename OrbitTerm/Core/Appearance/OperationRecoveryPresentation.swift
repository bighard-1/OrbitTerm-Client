import Foundation

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
