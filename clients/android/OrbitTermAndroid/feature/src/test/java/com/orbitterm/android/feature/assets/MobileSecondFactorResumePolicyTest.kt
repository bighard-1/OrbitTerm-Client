package com.orbitterm.android.feature.assets

import com.orbitterm.android.domain.assets.ServerTransportProtocol
import com.orbitterm.android.domain.session.ConnectionPhase
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileSecondFactorResumePolicyTest {
    private val intent = PendingSecondFactorResumeIntent("asset-id", "account-scope", 1_000L)

    @Test
    fun `capture requires an active second factor prompt and known account`() {
        val challenge = AssetConnectionUiState(
            "asset-id", ConnectionPhase.Connecting, secondFactorForJump = false,
        )
        assertTrue(MobileSecondFactorResumePolicy.capture(challenge, "account-scope", 1_000L) == intent)
        assertTrue(MobileSecondFactorResumePolicy.capture(challenge, null, 1_000L) == null)
        assertTrue(MobileSecondFactorResumePolicy.capture(challenge.copy(secondFactorForJump = null), "account-scope", 1_000L) == null)
    }

    @Test
    fun `same account can request one fresh challenge within five minutes`() {
        assertTrue(MobileSecondFactorResumePolicy.canResume(intent, "account-scope", 1_000L))
        assertTrue(MobileSecondFactorResumePolicy.canResume(intent, "account-scope", 301_000L))
    }

    @Test
    fun `expired future or different account intent cannot resume`() {
        assertFalse(MobileSecondFactorResumePolicy.canResume(intent, "account-scope", 301_001L))
        assertFalse(MobileSecondFactorResumePolicy.canResume(intent, "account-scope", 999L))
        assertFalse(MobileSecondFactorResumePolicy.canResume(intent, "other-account", 2_000L))
        assertFalse(MobileSecondFactorResumePolicy.canResume(intent, null, 2_000L))
    }

    @Test
    fun `only a verified SSH base session can auto open the terminal`() {
        val verified = AssetConnectionUiState("asset-id", ConnectionPhase.Connected, baseSessionId = 42L)
        assertTrue(verified.shouldAutoOpenVerifiedSsh())
        assertFalse(verified.copy(baseSessionId = null).shouldAutoOpenVerifiedSsh())
        assertFalse(verified.copy(phase = ConnectionPhase.Connecting).shouldAutoOpenVerifiedSsh())
        assertFalse(verified.copy(transport = ServerTransportProtocol.telnet).shouldAutoOpenVerifiedSsh())
        assertFalse(verified.copy(secondFactorForJump = false).shouldAutoOpenVerifiedSsh())
    }
}
