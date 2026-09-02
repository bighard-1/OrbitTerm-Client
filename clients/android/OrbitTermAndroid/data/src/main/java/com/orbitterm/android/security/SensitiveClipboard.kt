package com.orbitterm.android.security

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.widget.Toast
import java.security.MessageDigest

enum class ClipboardContentKind(
    val canCopy: Boolean,
    val clearAfterMillis: Long?,
    val notice: String?,
) {
    ORDINARY_TEXT(true, null, null),
    TERMINAL_OUTPUT(true, 60_000L, "终端内容已复制，将在 60 秒后自动清除。"),
    HOST_KEY_FINGERPRINT(true, 60_000L, "主机密钥指纹已复制，将在 60 秒后自动清除。"),
    CREDENTIAL(false, null, null),
    PRIVATE_KEY(false, null, null),
}

/**
 * Central clipboard boundary shared by every Android feature. Sensitive
 * terminal/fingerprint content is marked to suppress system previews and is
 * cleared only if the user has not copied a newer value.
 */
object SensitiveClipboard {
    private val mainHandler = Handler(Looper.getMainLooper())

    fun copy(
        context: Context,
        label: String,
        value: String,
        kind: ClipboardContentKind,
    ): Boolean {
        if (value.isEmpty() || !kind.canCopy) return false
        val clipboard = context.getSystemService(ClipboardManager::class.java) ?: return false
        val clip = ClipData.newPlainText(label, value)
        if (kind.clearAfterMillis != null) {
            clip.description.extras = PersistableBundle().apply {
                putBoolean(SENSITIVE_CLIP_EXTRA, true)
            }
        }
        clipboard.setPrimaryClip(clip)
        kind.notice?.let { Toast.makeText(context, it, Toast.LENGTH_SHORT).show() }

        val clearAfterMillis = kind.clearAfterMillis ?: return true
        val fingerprint = fingerprint(value)
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

    private const val SENSITIVE_CLIP_EXTRA = "android.content.extra.IS_SENSITIVE"
}
