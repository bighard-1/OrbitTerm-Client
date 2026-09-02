package com.orbitterm.android.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionNetworkAvailabilityTest {
    @Test
    fun `local transport is usable without a public internet validation input`() {
        assertTrue(sessionNetworkUsable(notSuspended = true, hasSupportedTransport = true))
    }

    @Test
    fun `suspended route or absent transport fails closed`() {
        assertFalse(sessionNetworkUsable(notSuspended = false, hasSupportedTransport = true))
        assertFalse(sessionNetworkUsable(notSuspended = true, hasSupportedTransport = false))
    }
}
