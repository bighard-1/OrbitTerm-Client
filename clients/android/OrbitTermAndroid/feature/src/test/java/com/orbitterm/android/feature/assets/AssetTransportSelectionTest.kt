package com.orbitterm.android.feature.assets

import com.orbitterm.android.domain.assets.ServerAuthMethod
import com.orbitterm.android.domain.assets.ServerTransportProtocol
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class AssetTransportSelectionTest {
    @Test
    fun selectingTelnetAppliesSafeDefaultsAndDisablesJumpHost() {
        val result = AssetEditorUiState(
            id = "asset",
            credentialID = "credential",
            isNew = true,
            createdAtUnix = 1,
            port = "22",
            authMethod = ServerAuthMethod.key,
            isJumpHostEnabled = true,
        ).selectTransport(ServerTransportProtocol.telnet)
        assertEquals("23", result.port)
        assertEquals(ServerAuthMethod.password, result.authMethod)
        assertFalse(result.isJumpHostEnabled)
    }

    @Test
    fun protocolChangeNeverOverwritesCustomPort() {
        val result = AssetEditorUiState(
            id = "asset",
            credentialID = "credential",
            isNew = true,
            createdAtUnix = 1,
            port = "2323",
        ).selectTransport(ServerTransportProtocol.telnet)
        assertEquals("2323", result.port)
    }
}
