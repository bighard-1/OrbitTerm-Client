package com.orbitterm.android.app

import com.orbitterm.android.domain.auth.AuthSession
import com.orbitterm.android.feature.presentation.OperationalFeedbackKind
import com.orbitterm.android.feature.presentation.OperationalFeedbackPolicy

enum class SecurityOperationFeedbackKind {
    SUCCESS,
    FAILURE,
    RECOVERY_REQUIRED,
}

enum class BiometricPromptFailure {
    CANCELLED,
    LOCKED_OUT,
    UNAVAILABLE,
    FAILED,
}

data class BiometricFailurePresentation(
    val kind: SecurityOperationFeedbackKind,
    val message: String,
)

data class SecurityOperationFeedback(
    val kind: SecurityOperationFeedbackKind,
    val message: String,
    val revision: Long,
) {
    val isError: Boolean
        get() = kind != SecurityOperationFeedbackKind.SUCCESS

    val autoDismissAfterMillis: Long?
        get() = OperationalFeedbackPolicy.lifetime(
            if (kind == SecurityOperationFeedbackKind.SUCCESS) {
                OperationalFeedbackKind.SUCCESS
            } else {
                OperationalFeedbackKind.FAILURE
            },
        ).autoDismissAfterMillis
}

object SecurityOperationPresentation {
    const val LOGIN_PASSWORD_SUCCESS = "已更新登录密码；其他设备需要重新登录。"
    const val MASTER_PASSWORD_SUCCESS = "已完成主密码轮换；其他设备需要重新登录并使用新主密码解锁。"
    const val LOCAL_COMMIT_SUCCESS = "已完成本地主密码更新。"
    const val LOGIN_PASSWORD_BUSY = "正在更新登录密码…"
    const val MASTER_PASSWORD_BUSY = "正在轮换主密码…"
    const val LOGOUT_TITLE = "退出登录？"
    const val LOGOUT_MESSAGE = "将断开当前所有会话并清除当前登录状态；本机加密数据仍按账户隔离保留。"
    const val LOGOUT_CONFIRM = "退出登录"
    const val BIOMETRIC_ENABLED_SUCCESS = "已启用生物识别解锁。"
    const val BIOMETRIC_DISABLED_SUCCESS = "已关闭生物识别解锁。"
    const val BIOMETRIC_UNLOCK_SUCCESS = "已通过生物识别解锁。"
    const val BIOMETRIC_INVALIDATED = "生物识别密钥已失效，请使用主密码解锁后重新启用。"
    const val BIOMETRIC_LOCKED_OUT = "生物识别暂时锁定，请使用主密码解锁。"
    const val BIOMETRIC_UNAVAILABLE = "此设备未配置可用的强生物识别方式。"
    const val BIOMETRIC_FAILED = "生物识别未通过，请重试或使用主密码解锁。"
    const val BIOMETRIC_BUSY = "正在验证…"
}

internal fun biometricFailurePresentation(
    failure: BiometricPromptFailure,
): BiometricFailurePresentation? = when (failure) {
    BiometricPromptFailure.CANCELLED -> null
    BiometricPromptFailure.LOCKED_OUT -> BiometricFailurePresentation(
        SecurityOperationFeedbackKind.FAILURE,
        SecurityOperationPresentation.BIOMETRIC_LOCKED_OUT,
    )
    BiometricPromptFailure.UNAVAILABLE -> BiometricFailurePresentation(
        SecurityOperationFeedbackKind.RECOVERY_REQUIRED,
        SecurityOperationPresentation.BIOMETRIC_UNAVAILABLE,
    )
    BiometricPromptFailure.FAILED -> BiometricFailurePresentation(
        SecurityOperationFeedbackKind.FAILURE,
        SecurityOperationPresentation.BIOMETRIC_FAILED,
    )
}

/**
 * A token refresh must not invalidate an in-flight operation for the same
 * account. Logout and account switching are represented by a missing or
 * different account and remain authoritative cancellation boundaries.
 */
internal fun securityOperationBelongsToCurrentAccount(
    currentSession: AuthSession?,
    expectedUsername: String,
): Boolean = currentSession?.username == expectedUsername
