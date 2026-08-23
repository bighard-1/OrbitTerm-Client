package com.orbitterm.android.feature.terminal

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TerminalCommandDispatchTest {
    @Test
    fun `snippet insertion never appends a submit character`() {
        assertArrayEquals(
            "printf 'ready'".toByteArray(Charsets.UTF_8),
            terminalInsertedCommandBytes("printf 'ready'"),
        )
    }

    @Test
    fun `snippet insertion preserves intentional whitespace`() {
        assertArrayEquals(
            "  echo value  ".toByteArray(Charsets.UTF_8),
            terminalInsertedCommandBytes("  echo value  "),
        )
    }

    @Test
    fun `blank snippets are ignored`() {
        assertNull(terminalInsertedCommandBytes(" \t"))
    }
}
