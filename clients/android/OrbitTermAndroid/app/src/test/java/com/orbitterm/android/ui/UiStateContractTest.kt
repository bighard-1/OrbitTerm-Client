package com.orbitterm.android.ui

import androidx.compose.ui.graphics.toArgb
import com.orbitterm.android.app.AppDestination
import com.orbitterm.android.domain.settings.AppColorTheme
import com.orbitterm.android.domain.settings.AppThemePreference
import com.orbitterm.android.domain.settings.TerminalThemePreference
import com.orbitterm.android.feature.docker.DockerUiState
import com.orbitterm.android.feature.monitor.MonitorUiState
import com.orbitterm.android.feature.sftp.SftpUiState
import com.orbitterm.android.ui.theme.appColorThemeAccent
import com.orbitterm.android.ui.theme.appColorThemeHighlight
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.pow

/** Guards safe UI defaults without requiring an SSH server, emulator data, or native bridge. */
class UiStateContractTest {
    @Test
    fun defaultRemoteWorkspacesNeverImplyAnActiveSessionOrTransfer() {
        val sftp = SftpUiState()
        assertNull(sftp.session)
        assertNull(sftp.sftpSessionId)
        assertNull(sftp.transfer)
        assertNull(sftp.activeTransferRequestId)
        assertFalse(sftp.canCancelTransfer)
        assertTrue(sftp.queuedTransfers.isEmpty())

        val docker = DockerUiState()
        assertNull(docker.session)
        assertTrue(docker.containers.isEmpty())
        assertFalse(docker.loading)
        assertNull(docker.actionContainerId)

        val monitor = MonitorUiState()
        assertNull(monitor.sessionId)
        assertNull(monitor.snapshot)
        assertFalse(monitor.loading)
        assertFalse(monitor.isPolling)
    }

    @Test
    fun applicationThemeContractKeepsEverySupportedModeAndOpaqueDistinctAccents() {
        assertEquals(
            setOf(AppThemePreference.System, AppThemePreference.Light, AppThemePreference.Dark),
            AppThemePreference.entries.toSet(),
        )
        assertEquals(AppColorTheme.entries.size, AppColorTheme.entries.map { appColorThemeAccent(it).toArgb() }.toSet().size)
        AppColorTheme.entries.forEach { theme ->
            assertEquals(0xFF, appColorThemeAccent(theme).toArgb().ushr(24))
            assertEquals(0xFF, appColorThemeHighlight(theme).toArgb().ushr(24))
        }
    }

    @Test
    fun terminalPalettesRemainCompleteAndIndependentFromApplicationTheme() {
        TerminalThemePreference.entries.forEach { theme ->
            assertEquals(16, theme.ansi16.size)
            assertTrue(theme.displayName.isNotBlank())
            assertTrue(
                "${theme.displayName} foreground must remain readable against its terminal background",
                contrastRatio(theme.foregroundArgb, theme.backgroundArgb) >= 4.5,
            )
        }
    }

    @Test
    fun sessionDockRemainsReachableUntilAtLeastOneTerminalIsLive() {
        assertEquals(
            setOf(
                AppDestination.Servers,
                AppDestination.Sessions,
                AppDestination.Sftp,
                AppDestination.Docker,
                AppDestination.More,
            ),
            AppDestination.entries.toSet(),
        )
        assertTrue(shouldShowBottomDock(AppDestination.Sessions, hasActiveTerminalSession = false))
        assertFalse(shouldShowBottomDock(AppDestination.Sessions, hasActiveTerminalSession = true))
        AppDestination.entries
            .filterNot { it == AppDestination.Sessions }
            .forEach { destination ->
                assertTrue(
                    "$destination must keep mobile navigation available while a terminal is active",
                    shouldShowBottomDock(destination, hasActiveTerminalSession = true),
                )
            }
    }

    private fun contrastRatio(foregroundArgb: Int, backgroundArgb: Int): Double {
        val foreground = relativeLuminance(foregroundArgb)
        val background = relativeLuminance(backgroundArgb)
        return (maxOf(foreground, background) + 0.05) / (minOf(foreground, background) + 0.05)
    }

    private fun relativeLuminance(argb: Int): Double {
        fun channel(shift: Int): Double {
            val value = ((argb ushr shift) and 0xFF) / 255.0
            return if (value <= 0.04045) value / 12.92 else ((value + 0.055) / 1.055).pow(2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
}
