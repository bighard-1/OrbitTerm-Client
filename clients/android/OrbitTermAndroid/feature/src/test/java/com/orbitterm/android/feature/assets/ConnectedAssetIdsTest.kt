package com.orbitterm.android.feature.assets

import com.orbitterm.android.feature.terminal.TerminalSessionConnectionState
import org.junit.Assert.assertEquals
import org.junit.Test

class ConnectedAssetIdsTest {
    @Test
    fun retainedDisconnectedTabsDoNotKeepAssetsMarkedConnected() {
        val sessions = listOf(
            "lost" to TerminalSessionConnectionState.Disconnected,
            "live" to TerminalSessionConnectionState.Connected,
            "live" to TerminalSessionConnectionState.Connected,
        )

        assertEquals(setOf("live"), connectedAssetIds(sessions))
    }
}
