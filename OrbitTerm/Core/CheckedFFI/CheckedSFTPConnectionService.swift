import Foundation

struct CheckedSFTPConnection: Hashable, Sendable {
    let workspaceID: UUID
    let baseSessionID: BaseSessionID
    let sftpSessionID: SFTPSessionID
    let homePath: String
}

enum CheckedSFTPServiceError: Error, Hashable, Sendable {
    case requiresVerifiedSession
    case checkedSFTPOpenFailed(CheckedFFIErrorCode?)
    case requestIDMismatch
    case unexpectedKind
    case legacySFTPDisabledInCheckedMode
    case sessionClosed
    case userCancelled
    case unknownCheckedFFIError
    case invalidSFTPSessionID
    case internalInvariant
}

extension CheckedSFTPServiceError: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        switch self {
        case .requiresVerifiedSession: "sftp_requires_verified_session"
        case let .checkedSFTPOpenFailed(code):
            "sftp_checked_open_failed:\(code?.rawValue ?? "unknown")"
        case .requestIDMismatch: "sftp_request_id_mismatch"
        case .unexpectedKind: "sftp_unexpected_result_kind"
        case .legacySFTPDisabledInCheckedMode: "sftp_legacy_disabled_in_checked_mode"
        case .sessionClosed: "sftp_base_session_closed"
        case .userCancelled: "sftp_user_cancelled"
        case .unknownCheckedFFIError: "sftp_unknown_checked_ffi_error"
        case .invalidSFTPSessionID: "sftp_invalid_session_id"
        case .internalInvariant: "sftp_internal_invariant"
        }
    }

    var debugDescription: String { description }

    var userMessage: String {
        switch self {
        case .requiresVerifiedSession, .legacySFTPDisabledInCheckedMode:
            "需要先建立已验证的 SSH 会话"
        case .sessionClosed:
            "已验证会话已关闭，请先重新连接"
        case .userCancelled:
            "已取消 SFTP 操作"
        case .requestIDMismatch, .unexpectedKind, .unknownCheckedFFIError,
             .invalidSFTPSessionID, .internalInvariant:
            "SFTP 安全响应无效，连接已停止"
        case .checkedSFTPOpenFailed:
            "无法从已验证会话打开 SFTP"
        }
    }
}

protocol CheckedSFTPConnectionOpening: Sendable {
    func open(
        workspaceID: UUID,
        baseSessionID: BaseSessionID
    ) async throws -> CheckedSFTPConnection
}

actor CheckedSFTPConnectionService: CheckedSFTPConnectionOpening {
    private let client: any CheckedFFIClient

    init(client: any CheckedFFIClient) {
        self.client = client
    }

    func open(
        workspaceID: UUID,
        baseSessionID: BaseSessionID
    ) async throws -> CheckedSFTPConnection {
        let requestID = HostKeyRequestID()
        do {
            let response = try await client.openSFTPChecked(
                requestID: requestID,
                baseSessionID: baseSessionID
            )
            guard response.requestID == requestID else {
                throw CheckedSFTPServiceError.requestIDMismatch
            }
            guard response.value.baseSessionID == baseSessionID else {
                throw CheckedSFTPServiceError.internalInvariant
            }
            return CheckedSFTPConnection(
                workspaceID: workspaceID,
                baseSessionID: baseSessionID,
                sftpSessionID: response.value.sftpSessionID,
                homePath: response.value.homePath ?? "/"
            )
        } catch let error as CheckedSFTPServiceError {
            throw error
        } catch let error as CheckedFFIClientError {
            throw Self.map(error)
        } catch {
            throw CheckedSFTPServiceError.unknownCheckedFFIError
        }
    }

    private static func map(_ error: CheckedFFIClientError) -> CheckedSFTPServiceError {
        switch error {
        case .requestIDMismatch:
            .requestIDMismatch
        case .unexpectedKind, .unknownKind:
            .unexpectedKind
        case let .ffiErrorPayload(payload):
            if payload.code.rawValue == "session_not_found" ||
                payload.code.rawValue == "session_closed" {
                .sessionClosed
            } else {
                .checkedSFTPOpenFailed(payload.code)
            }
        case .cancelled:
            .userCancelled
        case .invalidInput:
            .invalidSFTPSessionID
        case .unavailable, .timeout, .protocolViolation, .nullCStringResult,
             .invalidUTF8Result, .jsonDecodeFailed, .unsupportedSchema,
             .internalInvariant:
            .unknownCheckedFFIError
        }
    }
}

enum SFTPConnectionPlan: Hashable, Sendable {
    case legacy
    case checked(VerifiedWorkspaceSession)
    case rejected(CheckedSFTPServiceError)
}

struct SFTPConnectionPolicy: Sendable {
    let mode: ConnectionSecurityPolicy

    func plan(verifiedSession: VerifiedWorkspaceSession?) -> SFTPConnectionPlan {
        if mode.allowsLegacyNetwork {
            return .legacy
        }
        if let verifiedSession {
            return .checked(verifiedSession)
        }
        return .rejected(.requiresVerifiedSession)
    }
}
