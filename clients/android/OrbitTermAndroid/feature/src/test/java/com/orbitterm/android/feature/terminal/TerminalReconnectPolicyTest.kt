package com.orbitterm.android.feature.terminal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalReconnectPolicyTest {
    @Test
    fun `usable route permits only explicit idle reconnect`() {
        assertTrue(TerminalReconnectPolicy.canReconnect(isNetworkUsable = true, reconnecting = false))
        assertFalse(TerminalReconnectPolicy.canReconnect(isNetworkUsable = true, reconnecting = true))
        assertFalse(TerminalReconnectPolicy.canReconnect(isNetworkUsable = false, reconnecting = false))
    }

    @Test
    fun `accessibility labels distinguish waiting and in progress states`() {
        assertEquals(
            "等待网络恢复后重新连接",
            TerminalReconnectPolicy.accessibilityLabel(isNetworkUsable = false, reconnecting = false),
        )
        assertEquals(
            "正在重新连接当前会话",
            TerminalReconnectPolicy.accessibilityLabel(isNetworkUsable = true, reconnecting = true),
        )
    }
}
