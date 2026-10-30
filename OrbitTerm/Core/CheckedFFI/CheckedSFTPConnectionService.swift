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
        case .unavailable, .credentialUnavailable, .credentialStorageFailed,
             .timeout, .protocolViolation, .nullCStringResult,
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

private struct SFTPCheckedTransferPayload: Decodable {
    let sftpSessionID: String
    let path: String
    let securityGeneration: CheckedFFISecurityGeneration
    let byteLength: UInt64

    private enum CodingKeys: String, CodingKey {
        case sftpSessionID = "sftp_session_id"
        case path
        case securityGeneration = "security_generation"
        case byteLength = "byte_length"
    }
}

enum SFTPCheckedTransferError: LocalizedError {
    case cancelled
    case timeout
    case invalidResponse
    case failure(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "传输已取消"
        case .timeout: "传输超时，请检查连接和目标位置后重试"
        case .invalidResponse: "SFTP 安全响应无效，传输未确认完成"
        case let .failure(message): message
        }
    }
}

/// Checked transfers own their destination exclusively and can be cancelled
/// while the Rust FFI call is blocking a Swift worker thread.
enum SFTPCheckedTransfer {
    enum Direction: Sendable {
        case download
        case upload
    }

    static func download(
        sessionID: UInt64, remotePath: String, localURL: URL,
        cancellation: SFTPTransferCancellation? = nil
    ) async throws -> UInt64 {
        try await run(sessionID: sessionID, remotePath: remotePath,
                      localURL: localURL, direction: .download, cancellation: cancellation)
    }

    static func upload(
        sessionID: UInt64, localURL: URL, remotePath: String,
        cancellation: SFTPTransferCancellation? = nil
    ) async throws -> UInt64 {
        try await run(sessionID: sessionID, remotePath: remotePath,
                      localURL: localURL, direction: .upload, cancellation: cancellation)
    }

    private static func run(
        sessionID: UInt64,
        remotePath: String,
        localURL: URL,
        direction: Direction,
        cancellation: SFTPTransferCancellation?
    ) async throws -> UInt64 {
        let localPath = localURL.path
        let isDownload = direction == .download
        return try await execute(
            sessionID: sessionID, remotePath: remotePath, direction: direction,
            cancellation: cancellation,
            operation: { request in
                let pointer = remotePath.withCString { remote in
                    localPath.withCString { local in
                        request.withCString { requestPointer in
                            if isDownload {
                                orbit_sftp_download_checked_v1(
                                    sessionID, remote, local, requestPointer
                                )
                            } else {
                                orbit_sftp_upload_checked_v1(
                                    sessionID, local, remote, requestPointer
                                )
                            }
                        }
                    }
                }
                return try OrbitCStringResultReader.orbitCore.take(pointer)
            },
            cancel: { request in
                request.withCString { orbit_sftp_cancel_checked_v1($0) }
            }
        )
    }

    static func execute(
        sessionID: UInt64,
        remotePath: String,
        direction: Direction,
        timeout: TimeInterval = 50,
        cancellation: SFTPTransferCancellation? = nil,
        operation: @escaping @Sendable (String) throws -> String,
        cancel: @escaping @Sendable (String) -> Bool
    ) async throws -> UInt64 {
        let requestID = HostKeyRequestID()
        let lifetime = SFTPTransferLifetime()
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        // The Rust cancellation registry is populated inside the blocking call.
        // Retry until the call exits so cancellation just before registration
        // cannot leave a hidden transfer running.
        let cancellationWatcher = Task.detached(priority: .utility) {
            while !Task.isCancelled, !lifetime.isFinished {
                if cancellation?.isCancelled == true {
                    lifetime.requestCancellation(timedOut: false)
                }
                if ContinuousClock.now >= deadline {
                    lifetime.requestCancellation(timedOut: true)
                }
                if lifetime.isCancellationRequested {
                    _ = cancel(requestID.rawValue)
                }
                do {
                    try await Task.sleep(for: .milliseconds(25))
                } catch {
                    break
                }
            }
        }
        defer {
            lifetime.finish()
            cancellationWatcher.cancel()
        }
        return try await withTaskCancellationHandler {
            if Task.isCancelled || cancellation?.isCancelled == true {
                throw SFTPCheckedTransferError.cancelled
            }
            let raw: String = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard !lifetime.isCancellationRequested, cancellation?.isCancelled != true else {
                        continuation.resume(throwing: SFTPCheckedTransferError.cancelled)
                        return
                    }
                    do {
                        continuation.resume(returning: try operation(requestID.rawValue))
                    } catch {
                        continuation.resume(throwing: SFTPCheckedTransferError.invalidResponse)
                    }
                }
            }
            do {
                return try decode(raw, requestID: requestID, sessionID: sessionID,
                                  remotePath: remotePath, direction: direction)
            } catch SFTPCheckedTransferError.cancelled {
                if lifetime.didTimeOut { throw SFTPCheckedTransferError.timeout }
                throw SFTPCheckedTransferError.cancelled
            }
        } onCancel: {
            lifetime.requestCancellation(timedOut: false)
            _ = cancel(requestID.rawValue)
        }
    }
    static func decode(
        _ raw: String,
        requestID: HostKeyRequestID,
        sessionID: UInt64,
        remotePath: String,
        direction: Direction
    ) throws -> UInt64 {
        guard let data = raw.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(
                  CheckedFFIEnvelope<SFTPCheckedTransferPayload>.self, from: data
              ),
              (try? envelope.validateRequestID(requestID)) != nil else {
            throw SFTPCheckedTransferError.invalidResponse
        }
        if envelope.kind == .error {
            if ["sftp_download_failed", "sftp_upload_failed"].contains(envelope.error?.code.rawValue),
               envelope.error?.detailCode == "sftp_transfer_cancelled" {
                throw SFTPCheckedTransferError.cancelled
            }
            throw SFTPCheckedTransferError.failure(userMessage(
                code: envelope.error?.code.rawValue,
                detailCode: envelope.error?.detailCode,
                direction: direction
            ))
        }
        let expectedKind: CheckedFFIResultKind = direction == .download
            ? .sftpDownloadCompleted : .sftpUploadCompleted
        guard envelope.kind == expectedKind,
              let payload = envelope.data,
              payload.sftpSessionID == String(sessionID),
              payload.path == remotePath,
              payload.securityGeneration == .hostKeyVerified else {
            throw SFTPCheckedTransferError.invalidResponse
        }
        return payload.byteLength
    }

    private static func userMessage(
        code: String?, detailCode: String?, direction: Direction
    ) -> String {
        switch detailCode {
        case "sftp_transfer_cancelled": return "传输已取消"
        case "sftp_destination_exists": return direction == .download
            ? "保存目标已存在，未覆盖；请选择其他文件名"
            : "远端同名目标已存在，未覆盖"
        case "sftp_local_cleanup_failed": return "下载目标清理失败，请检查并删除本次部分文件"
        case "sftp_local_io_failed": return "本地保存位置不可访问；请检查是否留有部分文件"
        case "sftp_no_space_left": return "存储空间不足；请检查是否留有部分文件"
        case "sftp_permission_denied": return "读写权限不足，请检查目标位置"
        case "sftp_connection_closed": return "连接已断开，请重新连接后重试"
        case "sftp_source_not_found": return "源文件不存在或已移动"
        default:
            if ["session_not_found", "session_closed", "security_generation_mismatch",
                "legacy_session_not_allowed"].contains(code) {
                return "已验证会话失效，请重新连接后重试"
            }
            return "传输失败，请检查目标位置后重试"
        }
    }
}

private final class SFTPTransferLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var cancellationRequested = false
    private var timedOut = false

    var isFinished: Bool { lock.withLock { finished } }
    var isCancellationRequested: Bool { lock.withLock { cancellationRequested } }
    var didTimeOut: Bool { lock.withLock { timedOut } }

    func requestCancellation(timedOut: Bool) {
        lock.withLock {
            guard !finished, !cancellationRequested else { return }
            cancellationRequested = true
            self.timedOut = timedOut
        }
    }

    func finish() {
        lock.withLock { finished = true }
    }
}
