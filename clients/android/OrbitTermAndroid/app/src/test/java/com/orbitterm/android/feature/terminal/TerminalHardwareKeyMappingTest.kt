package com.orbitterm.android.feature.terminal

import android.view.KeyEvent
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class TerminalHardwareKeyMappingTest {
    @Test
    fun `ctrl letters use terminal control bytes even without unicode text`() {
        assertArrayEquals(byteArrayOf(3), terminalHardwareKeyBytes(KeyEvent.KEYCODE_C, 0, isCtrlPressed = true))
        assertArrayEquals(byteArrayOf(12), terminalHardwareKeyBytes(KeyEvent.KEYCODE_L, 0, isCtrlPressed = true))
    }

    @Test
    fun `editing and navigation keys use terminal escape sequences`() {
        assertArrayEquals("\u001B[3~".toByteArray(), terminalHardwareKeyBytes(KeyEvent.KEYCODE_FORWARD_DEL, 0, false))
        assertArrayEquals("\u001B[5~".toByteArray(), terminalHardwareKeyBytes(KeyEvent.KEYCODE_PAGE_UP, 0, false))
        assertArrayEquals("\u001B[F".toByteArray(), terminalHardwareKeyBytes(KeyEvent.KEYCODE_MOVE_END, 0, false))
    }

    @Test
    fun `unicode fallback preserves international IME compatible input`() {
        assertEquals("中", terminalHardwareKeyBytes(KeyEvent.KEYCODE_UNKNOWN, '中'.code, false)?.toString(Charsets.UTF_8))
    }
}
