package com.orbitterm.android.feature.terminal

import android.content.ClipboardManager
import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

sealed interface TerminalClipboardContent {
    data class Text(val bytes: ByteArray) : TerminalClipboardContent
    data object Empty : TerminalClipboardContent
    data object TooLarge : TerminalClipboardContent
}

/** Reads the clipboard only for an explicit terminal paste and never retains its contents. */
@Singleton
class TerminalClipboard @Inject constructor(
    @param:ApplicationContext private val context: Context,
) {
    fun readForPaste(): TerminalClipboardContent {
        val clipboard = context.getSystemService(ClipboardManager::class.java) ?: return TerminalClipboardContent.Empty
        val item = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0) ?: return TerminalClipboardContent.Empty
        val text = item.coerceToText(context)?.toString()?.takeIf { it.isNotEmpty() } ?: return TerminalClipboardContent.Empty
        if (text.toByteArray(Charsets.UTF_8).size > MAX_PASTE_BYTES) return TerminalClipboardContent.TooLarge
        return TerminalClipboardContent.Text(text.toByteArray(Charsets.UTF_8))
    }

    private companion object { const val MAX_PASTE_BYTES = 16 * 1024 }
}
