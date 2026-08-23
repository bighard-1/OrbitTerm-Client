package com.orbitterm.android.security

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.security.MessageDigest

/**
 * Copies an explicitly selected sensitive value and clears it after a bounded
 * interval only when the user has not copied something else in the meantime.
 */
object SensitiveClipboard {
    private val mainHandler = Handler(Looper.getMainLooper())

    fun copy(
        context: Context,
        label: String,
        value: String,
        clearAfterMillis: Long = DEFAULT_CLEAR_AFTER_MILLIS,
    ): Boolean {
        if (value.isEmpty()) return false
        val clipboard = context.getSystemService(ClipboardManager::class.java) ?: return false
        val fingerprint = fingerprint(value)
        clipboard.setPrimaryClip(ClipData.newPlainText(label, value))
        mainHandler.postDelayed({
            val current = clipboard.primaryClip
                ?.takeIf { it.itemCount > 0 }
                ?.getItemAt(0)
                ?.coerceToText(context)
                ?.toString()
            if (current != null && fingerprint(current) == fingerprint) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) clipboard.clearPrimaryClip()
                else clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
            }
        }, clearAfterMillis)
        return true
    }

    private fun fingerprint(value: String): String = MessageDigest
        .getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString(separator = "") { byte -> "%02x".format(byte) }

    private const val DEFAULT_CLEAR_AFTER_MILLIS = 60_000L
}
