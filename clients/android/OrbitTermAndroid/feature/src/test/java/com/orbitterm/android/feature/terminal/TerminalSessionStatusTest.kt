package com.orbitterm.android.feature.terminal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalSessionStatusTest {
    @Test
    fun `terminal header distinguishes connected and reconnecting without online wording`() {
        val connected = terminalSessionStatusLabel(
            state = TerminalSessionConnectionState.Connected,
            reconnecting = false,
            sessionCount = 2,
        )
        val disconnected = terminalSessionStatusLabel(
            state = TerminalSessionConnectionState.Disconnected,
            reconnecting = false,
            sessionCount = 2,
        )
        val reconnecting = terminalSessionStatusLabel(
            state = TerminalSessionConnectionState.Disconnected,
            reconnecting = true,
            sessionCount = 2,
        )

        assertEquals("已连接 · 2 个会话", connected)
        assertEquals("已断开 · 2 个会话", disconnected)
        assertEquals("重连中 · 2 个会话", reconnecting)
        assertFalse(connected.contains("在线"))
        assertFalse(reconnecting.contains("在线"))
    }

    @Test
    fun `only definitive native closure codes invalidate connected presentation`() {
        assertTrue(terminalFailureClosesSession("session_closed"))
        assertTrue(terminalFailureClosesSession("session_not_found"))
        assertFalse(terminalFailureClosesSession("native_operation_failed"))
        assertFalse(terminalFailureClosesSession("network_timeout"))
    }
}
