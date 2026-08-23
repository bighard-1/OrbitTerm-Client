package com.orbitterm.android.feature.terminal

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class TelnetNegotiationParserTest {
    @Test
    fun removesNegotiationBytesWithoutDroppingTerminalText() {
        val negotiations = mutableListOf<Pair<Int, Int>>()
        val parser = TelnetNegotiationParser { command, option -> negotiations += command to option }
        val source = byteArrayOf(
            'l'.code.toByte(), 'o'.code.toByte(), 255.toByte(), 251.toByte(), 1,
            'g'.code.toByte(), 'i'.code.toByte(), 'n'.code.toByte(), ':'.code.toByte(),
        )
        val payload = parser.consume(source, source.size)
        assertArrayEquals("login:".toByteArray(), payload)
        assertEquals(listOf(251 to 1), negotiations)
    }

    @Test
    fun escapedIacRemainsTerminalData() {
        val parser = TelnetNegotiationParser { _, _ -> }
        val payload = parser.consume(byteArrayOf('a'.code.toByte(), 255.toByte(), 255.toByte(), 'b'.code.toByte()), 4)
        assertArrayEquals(byteArrayOf('a'.code.toByte(), 255.toByte(), 'b'.code.toByte()), payload)
    }
}
