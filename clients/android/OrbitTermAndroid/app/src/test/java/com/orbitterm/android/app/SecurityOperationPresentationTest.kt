package com.orbitterm.android.app

import com.orbitterm.android.domain.auth.AuthSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SecurityOperationPresentationTest {
    @Test
    fun successIsTransientWhileFailureAndRecoveryRemainPersistent() {
        val success = SecurityOperationFeedback(
            SecurityOperationFeedbackKind.SUCCESS,
            SecurityOperationPresentation.LOGIN_PASSWORD_SUCCESS,
            1,
        )
        val failure = SecurityOperationFeedback(SecurityOperationFeedbackKind.FAILURE, "更新失败", 2)
        val recovery = SecurityOperationFeedback(SecurityOperationFeedbackKind.RECOVERY_REQUIRED, "需要恢复", 3)

        assertFalse(success.isError)
        assertEquals(4_000L, success.autoDismissAfterMillis)
        assertTrue(failure.isError)
        assertNull(failure.autoDismissAfterMillis)
        assertTrue(recovery.isError)
        assertNull(recovery.autoDismissAfterMillis)
    }

    @Test
    fun highRiskVocabularyMatchesAppleContract() {
        assertEquals("已更新登录密码；其他设备需要重新登录。", SecurityOperationPresentation.LOGIN_PASSWORD_SUCCESS)
        assertEquals(
            "已完成主密码轮换；其他设备需要重新登录并使用新主密码解锁。",
            SecurityOperationPresentation.MASTER_PASSWORD_SUCCESS,
        )
        assertEquals("退出登录？", SecurityOperationPresentation.LOGOUT_TITLE)
        assertEquals("退出登录", SecurityOperationPresentation.LOGOUT_CONFIRM)
    }

    @Test
    fun tokenRefreshKeepsSameAccountOperationValidButLogoutAndSwitchDoNot() {
        val refreshedSession = AuthSession(
            username = "operator@example.com",
            accessToken = "refreshed-token",
        )

        assertTrue(
            securityOperationBelongsToCurrentAccount(
                refreshedSession,
                expectedUsername = "operator@example.com",
            ),
        )
        assertFalse(
            securityOperationBelongsToCurrentAccount(
                refreshedSession,
                expectedUsername = "other@example.com",
            ),
        )
        assertFalse(
            securityOperationBelongsToCurrentAccount(
                currentSession = null,
                expectedUsername = "operator@example.com",
            ),
        )
    }

    @Test
    fun biometricFailuresUseStableRecoveryVocabularyAndCancellationIsSilent() {
        assertNull(biometricFailurePresentation(BiometricPromptFailure.CANCELLED))
        assertEquals(
            SecurityOperationPresentation.BIOMETRIC_LOCKED_OUT,
            biometricFailurePresentation(BiometricPromptFailure.LOCKED_OUT)?.message,
        )
        assertEquals(
            SecurityOperationFeedbackKind.RECOVERY_REQUIRED,
            biometricFailurePresentation(BiometricPromptFailure.UNAVAILABLE)?.kind,
        )
        assertEquals(
            SecurityOperationPresentation.BIOMETRIC_FAILED,
            biometricFailurePresentation(BiometricPromptFailure.FAILED)?.message,
        )
    }
}
