package com.orbitterm.android.domain.error

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Stable, content-free failures shared across Android layers.
 *
 * `diagnosticCode` is deliberately an allow-listed value. Remote exception text,
 * host names, paths, commands, credentials and server response bodies never
 * become a user-facing diagnostic code or an observability attribute.
 */
enum class OrbitErrorCode(val diagnosticCode: String) {
    InvalidRequest("invalid_request"),
    NativeBridgeUnavailable("native_bridge_unavailable"),
    NativeProtocolInvalid("native_protocol_invalid"),
    NativeOperationFailed("native_operation_failed"),
    OperationCancelled("operation_cancelled"),
    StaleOperation("stale_operation"),
    NetworkUnavailable("network_unavailable"),
    NetworkTimeout("network_timeout"),
    AuthenticationFailed("authentication_failed"),
    AuthenticationExpired("authentication_expired"),
    HostKeyBlocked("host_key_blocked"),
    PermissionDenied("permission_denied"),
    StorageUnavailable("storage_unavailable"),
    StorageLocked("storage_locked"),
    SftpConflict("sftp_conflict"),
    SftpOperationFailed("sftp_operation_failed"),
    DockerOperationFailed("docker_operation_failed"),
    MonitorOperationFailed("monitor_operation_failed"),
    SyncConflict("sync_conflict"),
    SyncDecryptionFailed("sync_decryption_failed"),
    RemoteServiceRejected("remote_service_rejected"),
    Unknown("unknown"),
}

enum class OrbitRecoveryAction {
    Retry,
    CheckNetwork,
    CheckCredentials,
    SignInAgain,
    Unlock,
    ReviewHostKey,
    CheckPermission,
    ResolveConflict,
    ReopenSession,
    ContactSupport,
    None,
}

data class OrbitError(
    val code: OrbitErrorCode,
    val retryable: Boolean,
    val recovery: OrbitRecoveryAction,
) {
    val diagnosticCode: String get() = code.diagnosticCode

    fun userMessage(): String = when (code) {
        OrbitErrorCode.InvalidRequest -> "请求内容无效，请检查后重试。"
        OrbitErrorCode.NativeBridgeUnavailable -> "本机安全连接组件不可用，请重启应用后重试。"
        OrbitErrorCode.NativeProtocolInvalid, OrbitErrorCode.NativeOperationFailed -> "本机连接组件未能完成操作，请重新建立会话后重试。"
        OrbitErrorCode.OperationCancelled -> "操作已取消。"
        OrbitErrorCode.StaleOperation -> "会话已切换，本次操作未继续执行。"
        OrbitErrorCode.NetworkUnavailable -> "网络不可用，请检查网络后重试。"
        OrbitErrorCode.NetworkTimeout -> "连接超时，请检查网络、地址和防火墙。"
        OrbitErrorCode.AuthenticationFailed -> "认证失败，请检查账号、密码或私钥。"
        OrbitErrorCode.AuthenticationExpired -> "登录已过期，请重新登录后重试。"
        OrbitErrorCode.HostKeyBlocked -> "主机密钥校验未通过，连接已被安全阻断。"
        OrbitErrorCode.PermissionDenied -> "权限不足，请检查远端账户或文件权限。"
        OrbitErrorCode.StorageUnavailable -> "本机安全存储不可用，请解锁设备后重试。"
        OrbitErrorCode.StorageLocked -> "需要解锁应用后才能继续此操作。"
        OrbitErrorCode.SftpConflict -> "远端文件已变化，请刷新目录后重试。"
        OrbitErrorCode.SftpOperationFailed -> "SFTP 操作未完成，请重新建立会话后重试。"
        OrbitErrorCode.DockerOperationFailed -> "Docker 操作未完成，请确认会话和容器状态后重试。"
        OrbitErrorCode.MonitorOperationFailed -> "监控采样未完成，请确认 SSH 会话后重试。"
        OrbitErrorCode.SyncConflict -> "同步发现冲突，请处理冲突后再同步。"
        OrbitErrorCode.SyncDecryptionFailed -> "同步数据无法解密，请确认主密码后重试。"
        OrbitErrorCode.RemoteServiceRejected -> "服务暂未接受该请求，请稍后重试。"
        OrbitErrorCode.Unknown -> "操作失败，请稍后重试。"
    }
}

/**
 * Process-local counters for support diagnostics. They intentionally retain no
 * timestamps, exception text, account identifiers, hosts, paths or commands,
 * and are never responsible for uploading anything.
 */
object PrivacySafeErrorMetrics {
    private val counts = ConcurrentHashMap<OrbitErrorCode, AtomicInteger>()

    fun record(error: OrbitError) {
        counts.getOrPut(error.code) { AtomicInteger() }.incrementAndGet()
    }

    fun snapshot(): Map<OrbitErrorCode, Int> = counts.entries
        .associate { (code, count) -> code to count.get() }
        .filterValues { it > 0 }

    internal fun clearForTests() = counts.clear()
}

/** Converts only known protocol tokens. Unknown text is safely collapsed. */
fun orbitNativeError(rawCode: String?, retryable: Boolean = false, detailCode: String? = null): OrbitError {
    val code = when (rawCode) {
        "invalid_exec_request", "invalid_terminal_request", "invalid_sftp_list_request", "invalid_sftp_read_request", "invalid_docker_action" -> OrbitErrorCode.InvalidRequest
        "native_bridge_unavailable", "native_bridge_failed" -> OrbitErrorCode.NativeBridgeUnavailable
        "invalid_native_response", "uncorrelated_native_response", "invalid_connected_response", "invalid_host_key_challenge",
        "invalid_terminal_open_response", "invalid_exec_response", "invalid_sftp_open_response", "invalid_sftp_list_response",
        "invalid_sftp_text_response", "invalid_docker_list_response", "invalid_docker_logs_response", "invalid_docker_stats_response",
        "invalid_monitor_snapshot" -> OrbitErrorCode.NativeProtocolInvalid
        "sftp_transfer_cancelled" -> OrbitErrorCode.OperationCancelled
        "sftp_transfer_session_changed", "entry_changed" -> OrbitErrorCode.StaleOperation
        "ssh_timeout" -> if (detailCode == "authentication_timeout") OrbitErrorCode.AuthenticationFailed else OrbitErrorCode.NetworkTimeout
        "ssh_connect_failed" -> OrbitErrorCode.NetworkUnavailable
        "ssh_auth_failed", "jump_credentials_unavailable" -> OrbitErrorCode.AuthenticationFailed
        "host_key_blocked", "host_key_changed", "host_key_revoked" -> OrbitErrorCode.HostKeyBlocked
        "permission_denied", "sftp_permission_denied" -> OrbitErrorCode.PermissionDenied
        "destination_unwritable", "archive_workspace_unavailable", "archive_write_failed", "local_file_unreadable" -> OrbitErrorCode.StorageUnavailable
        "sftp_conflict", "sftp_mutation_conflict", "sftp_target_exists" -> OrbitErrorCode.SftpConflict
        "sftp_mutation_failed", "sftp_operation_failed", "delete_depth_limit", "delete_entry_limit", "unsafe_remote_name" -> OrbitErrorCode.SftpOperationFailed
        "docker_operation_failed" -> OrbitErrorCode.DockerOperationFailed
        "monitor_operation_failed" -> OrbitErrorCode.MonitorOperationFailed
        "native_operation_failed" -> OrbitErrorCode.NativeOperationFailed
        else -> OrbitErrorCode.Unknown
    }
    val recovery = when (code) {
        OrbitErrorCode.NetworkUnavailable, OrbitErrorCode.NetworkTimeout -> OrbitRecoveryAction.CheckNetwork
        OrbitErrorCode.AuthenticationFailed -> OrbitRecoveryAction.CheckCredentials
        OrbitErrorCode.AuthenticationExpired -> OrbitRecoveryAction.SignInAgain
        OrbitErrorCode.HostKeyBlocked -> OrbitRecoveryAction.ReviewHostKey
        OrbitErrorCode.PermissionDenied -> OrbitRecoveryAction.CheckPermission
        OrbitErrorCode.StorageUnavailable -> OrbitRecoveryAction.Unlock
        OrbitErrorCode.SftpConflict, OrbitErrorCode.SyncConflict -> OrbitRecoveryAction.ResolveConflict
        OrbitErrorCode.StaleOperation, OrbitErrorCode.NativeBridgeUnavailable, OrbitErrorCode.NativeProtocolInvalid,
        OrbitErrorCode.NativeOperationFailed, OrbitErrorCode.SftpOperationFailed, OrbitErrorCode.DockerOperationFailed,
        OrbitErrorCode.MonitorOperationFailed -> OrbitRecoveryAction.ReopenSession
        OrbitErrorCode.OperationCancelled -> OrbitRecoveryAction.None
        else -> if (retryable) OrbitRecoveryAction.Retry else OrbitRecoveryAction.ContactSupport
    }
    return OrbitError(code, retryable && code !in setOf(OrbitErrorCode.OperationCancelled, OrbitErrorCode.InvalidRequest), recovery)
        .also(PrivacySafeErrorMetrics::record)
}

fun syncError(code: OrbitErrorCode): OrbitError = OrbitError(
    code = code,
    retryable = code in setOf(OrbitErrorCode.NetworkUnavailable, OrbitErrorCode.NetworkTimeout, OrbitErrorCode.RemoteServiceRejected),
    recovery = when (code) {
        OrbitErrorCode.AuthenticationExpired -> OrbitRecoveryAction.SignInAgain
        OrbitErrorCode.SyncDecryptionFailed -> OrbitRecoveryAction.Unlock
        OrbitErrorCode.SyncConflict -> OrbitRecoveryAction.ResolveConflict
        OrbitErrorCode.NetworkUnavailable, OrbitErrorCode.NetworkTimeout -> OrbitRecoveryAction.CheckNetwork
        else -> OrbitRecoveryAction.Retry
    },
).also(PrivacySafeErrorMetrics::record)
