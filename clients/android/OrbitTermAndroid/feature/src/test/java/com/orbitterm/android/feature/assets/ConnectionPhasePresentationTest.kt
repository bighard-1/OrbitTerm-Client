package com.orbitterm.android.feature.assets

import com.orbitterm.android.domain.session.ConnectionError
import com.orbitterm.android.domain.session.ConnectionPhase
import com.orbitterm.android.domain.session.DisconnectReason
import org.junit.Assert.assertEquals
import org.junit.Test

class ConnectionPhasePresentationTest {
    @Test
    fun `connection phases use the shared mobile vocabulary`() {
        assertEquals("连接中", ConnectionPhase.Connecting.presentationHeadline())
        assertEquals("重连中", ConnectionPhase.Reconnecting(2, 123L).presentationHeadline())
        assertEquals("已连接", ConnectionPhase.Connected.presentationHeadline())
        assertEquals("已断开", ConnectionPhase.Disconnected(DisconnectReason.NetworkLost).presentationHeadline())
        assertEquals(
            "连接失败",
            ConnectionPhase.Failed(ConnectionError.NetworkUnavailable, retryable = true).presentationHeadline(),
        )
    }
}
