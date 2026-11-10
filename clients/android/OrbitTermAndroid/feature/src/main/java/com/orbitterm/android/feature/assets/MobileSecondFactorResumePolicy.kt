package com.orbitterm.android.feature.assets

import com.orbitterm.android.domain.assets.ServerTransportProtocol
import com.orbitterm.android.domain.session.ConnectionPhase

/** Only route identity survives a mobile lock; a code or checked SSH handle never does. */
internal data class PendingSecondFactorResumeIntent(
    val assetId: String,
    val accountScopeId: String,
    val capturedAtMillis: Long,
)

internal object MobileSecondFactorResumePolicy {
    const val MAXIMUM_AGE_MILLIS = 5 * 60 * 1000L

    fun capture(
        connection: AssetConnectionUiState?,
        accountScopeId: String?,
        nowMillis: Long,
    ): PendingSecondFactorResumeIntent? =
        if (connection?.secondFactorForJump != null && accountScopeId != null) {
            PendingSecondFactorResumeIntent(connection.assetId, accountScopeId, nowMillis)
        } else null

    fun canResume(
        intent: PendingSecondFactorResumeIntent,
        accountScopeId: String?,
        nowMillis: Long,
    ): Boolean = accountScopeId != null &&
        accountScopeId == intent.accountScopeId &&
        nowMillis >= intent.capturedAtMillis &&
        nowMillis - intent.capturedAtMillis <= MAXIMUM_AGE_MILLIS
}

internal fun AssetConnectionUiState.shouldAutoOpenVerifiedSsh(): Boolean =
    transport == ServerTransportProtocol.ssh &&
        phase == ConnectionPhase.Connected &&
        baseSessionId?.let { it > 0 } == true &&
        hostKeyChallenge == null &&
        secondFactorForJump == null
