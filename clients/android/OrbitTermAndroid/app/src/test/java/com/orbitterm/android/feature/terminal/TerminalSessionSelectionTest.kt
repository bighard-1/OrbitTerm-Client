package com.orbitterm.android.feature.terminal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TerminalSessionSelectionTest {
    @Test
    fun `uses the selected session instead of the most recently opened one`() {
        val older = session("older")
        val newer = session("newer")

        assertEquals(older, selectActiveTerminalSession(listOf(older, newer), older.id))
    }

    @Test
    fun `uses the most recently opened session only when no selection is available`() {
        val older = session("older")
        val newer = session("newer")

        assertEquals(newer, selectActiveTerminalSession(listOf(older, newer), null))
        assertEquals(newer, selectActiveTerminalSession(listOf(older, newer), "closed"))
    }

    @Test
    fun `returns no session when none are live`() {
        assertNull(selectActiveTerminalSession(emptyList(), "any"))
    }

    private fun session(id: String) = ActiveTerminalSession(
        id = id,
        assetId = "asset-$id",
        displayName = id,
        baseSessionId = id.hashCode().toLong(),
        terminalChannelId = id.hashCode().toLong(),
        engine = RemoteTerminalEngine(columns = 80, rows = 24, onInput = {}),
    )
}
