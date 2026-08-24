package com.orbitterm.android.domain.remote

import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteDesktopAdapterTest {
    @Test
    fun windowsAndLinuxTargetsAreAcceptedButMacosIsRejected() {
        profile(RemoteDesktopTargetPlatform.windows)
        profile(RemoteDesktopTargetPlatform.linux)
        val error = assertThrows(RemoteDesktopAdapterException::class.java) {
            profile(RemoteDesktopTargetPlatform.macos)
        }
        assertEquals(RemoteDesktopFailureKind.invalidTarget, error.kind)
    }

    @Test
    fun deferredAdapterFailsClosed() = runBlocking {
        val adapter = DeferredFreeRdpAdapter()
        assertEquals(RemoteDesktopRuntimeCapability.unavailable, adapter.capability)
        try {
            adapter.open(profile(RemoteDesktopTargetPlatform.windows))
            throw AssertionError("Unavailable runtime must not open a session")
        } catch (error: RemoteDesktopAdapterException) {
            assertEquals(RemoteDesktopFailureKind.engineUnavailable, error.kind)
        }
    }

    @Test
    fun closedSessionCannotBeRevived() {
        val machine = RemoteDesktopSessionStateMachine()
        assertTrue(machine.transitionTo(RemoteDesktopSessionPhase.authenticating))
        assertTrue(machine.transitionTo(RemoteDesktopSessionPhase.connected))
        assertTrue(machine.transitionTo(RemoteDesktopSessionPhase.closed))
        assertFalse(machine.transitionTo(RemoteDesktopSessionPhase.connected))
    }

    private fun profile(target: RemoteDesktopTargetPlatform) = RemoteDesktopConnectionProfile(
        assetId = UUID.randomUUID(),
        host = "rdp.example.test",
        port = 3389,
        targetPlatform = target,
        credentialId = UUID.randomUUID(),
    )
}
