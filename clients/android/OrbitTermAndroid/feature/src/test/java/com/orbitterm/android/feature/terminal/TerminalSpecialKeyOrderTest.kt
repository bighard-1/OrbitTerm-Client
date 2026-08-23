package com.orbitterm.android.feature.terminal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalSpecialKeyOrderTest {
    @Test
    fun mobileAccessoryContainsIosParityKeys() {
        val labels = terminalSpecialKeys.map { it.label }
        assertTrue(labels.containsAll(listOf("Tab", "Ctrl+C", "Esc", "↑", "↓", "←", "→")))
        assertTrue(labels.containsAll(listOf("+", "-", "*", "/", "_", "(", ")", "[", "]", "{", "}")))
    }
    @Test
    fun `usage count moves a special key ahead of default order`() {
        val ordered = orderedTerminalSpecialKeys(mapOf("#" to 5, "{" to 2))

        assertEquals(listOf("#", "{"), ordered.take(2).map(TerminalSpecialKey::label))
    }

    @Test
    fun `unused keys retain the curated default order`() {
        val ordered = orderedTerminalSpecialKeys(emptyMap())

        assertEquals(listOf("Enter", "Ctrl+C"), ordered.take(2).map(TerminalSpecialKey::label))
        assertTrue(ordered.map(TerminalSpecialKey::label).containsAll(listOf("_", "(", ")", "[", "]", "{", "}", "<", ">", "~", "#")))
    }

    @Test
    fun `symbol usage participates in stable ordering`() {
        val ordered = orderedTerminalSpecialKeys(mapOf("#" to 9, "_" to 4))

        assertEquals(listOf("#", "_"), ordered.take(2).map(TerminalSpecialKey::label))
    }

    @Test
    fun `custom keys participate in the same usage ordering`() {
        val custom = TerminalSpecialKey("管道", byteArrayOf('|'.code.toByte()), id = "custom:pipe")
        val ordered = orderedTerminalSpecialKeys(mapOf("管道" to 7), terminalSpecialKeys + custom)

        assertEquals("custom:pipe", ordered.first().id)
    }

    @Test
    fun `custom key payload supports audited escapes and rejects invalid sequences`() {
        assertEquals(listOf(9, 27, 65), parseTerminalCustomKeyPayload("\\t\\eA")?.map(Byte::toInt))
        assertEquals(listOf(124), parseTerminalCustomKeyPayload("\\x7c")?.map { it.toInt() and 0xff })
        assertEquals(null, parseTerminalCustomKeyPayload("\\q"))
        assertEquals(null, parseTerminalCustomKeyPayload("\\x0"))
    }
}
