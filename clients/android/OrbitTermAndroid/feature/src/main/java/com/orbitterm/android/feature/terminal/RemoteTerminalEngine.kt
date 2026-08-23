package com.orbitterm.android.feature.terminal

import com.orbitterm.android.domain.performance.RuntimeResourceBudget
import com.termux.terminal.TerminalEmulator
import com.termux.terminal.TerminalOutput

/**
 * Adapts the ANSI/VT emulator to a remote SSH channel. It deliberately owns no
 * process: all input is sent through [onInput], and all output is appended by
 * the checked SSH session on the Android main thread.
 */
class RemoteTerminalEngine(
    columns: Int,
    rows: Int,
    private val onInput: (ByteArray) -> Unit,
    private val onTitleChanged: (String) -> Unit = {},
    private val onBell: () -> Unit = {},
    private val onPaletteChanged: () -> Unit = {},
) {
    val emulator = TerminalEmulator(
        RemoteTerminalOutput(),
        columns.coerceIn(MIN_COLUMNS, MAX_COLUMNS),
        rows.coerceIn(MIN_ROWS, MAX_ROWS),
        CELL_WIDTH_PIXELS,
        CELL_HEIGHT_PIXELS,
        RuntimeResourceBudget.TERMINAL_TRANSCRIPT_ROWS,
        null,
    )

    fun append(bytes: ByteArray) {
        if (bytes.isNotEmpty()) emulator.append(bytes, bytes.size)
    }

    fun sendInput(bytes: ByteArray) {
        if (bytes.isNotEmpty()) onInput(bytes)
    }

    fun resize(columns: Int, rows: Int) {
        emulator.resize(
            columns.coerceIn(MIN_COLUMNS, MAX_COLUMNS),
            rows.coerceIn(MIN_ROWS, MAX_ROWS),
            CELL_WIDTH_PIXELS,
            CELL_HEIGHT_PIXELS,
        )
    }

    private inner class RemoteTerminalOutput : TerminalOutput() {
        override fun write(data: ByteArray, offset: Int, count: Int) {
            if (count > 0) onInput(data.copyOfRange(offset, offset + count))
        }

        override fun titleChanged(oldTitle: String?, newTitle: String?) {
            onTitleChanged(newTitle.orEmpty())
        }

        override fun onCopyTextToClipboard(text: String?) = Unit

        override fun onPasteTextFromClipboard() = Unit

        override fun onBell() = onBell.invoke()

        override fun onColorsChanged() = onPaletteChanged.invoke()
    }

    private companion object {
        const val MIN_COLUMNS = 2
        const val MAX_COLUMNS = 1_000
        const val MIN_ROWS = 2
        const val MAX_ROWS = 1_000
        const val CELL_WIDTH_PIXELS = 1
        const val CELL_HEIGHT_PIXELS = 1
    }
}
