package com.orbitterm.android.feature.terminal

import org.junit.Assert.assertEquals
import org.junit.Test

class TerminalSpecialKeyOrderTest {
    @Test
    fun mobileAccessoryContainsIosParityKeys() {
        assertEquals(
            listOf("Enter", "Ctrl+C", "Ctrl+D", "Ctrl+L", "Ctrl+U", "Esc", "Tab", "↑", "↓", "←", "→"),
            terminalCommonKeys.map(TerminalSpecialKey::label),
        )
        assertEquals(
            listOf("←", "↑", "↓", "→", "-", "+", "×", "/", "|", "\\", "~", "=", "_", "$", "#", ";", ":", "?"),
            terminalSymbolKeys.map(TerminalSpecialKey::label),
        )
    }
    @Test
    fun `curated order is stable and custom keys preserve user order`() {
        val custom = TerminalSpecialKey("管道", byteArrayOf('|'.code.toByte()), id = "custom:pipe")

        assertEquals(listOf("Enter", "Ctrl+C"), terminalCommonKeys.take(2).map(TerminalSpecialKey::label))
        assertEquals("custom:pipe", (terminalCommonKeys + custom).last().id)
    }

    @Test
    fun `custom key payload supports audited escapes and rejects invalid sequences`() {
        assertEquals(listOf(9, 27, 65), parseTerminalCustomKeyPayload("\\t\\eA")?.map(Byte::toInt))
        assertEquals(listOf(124), parseTerminalCustomKeyPayload("\\x7c")?.map { it.toInt() and 0xff })
        assertEquals(null, parseTerminalCustomKeyPayload("\\q"))
        assertEquals(null, parseTerminalCustomKeyPayload("\\x0"))
    }
}
