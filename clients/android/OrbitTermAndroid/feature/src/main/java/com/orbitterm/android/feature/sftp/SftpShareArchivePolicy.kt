package com.orbitterm.android.feature.sftp

import com.orbitterm.android.core.SftpDirectoryEntry

/**
 * Pure presentation and retention policy for an Android-native SFTP share.
 * The archive itself stays in private cache; only FileProvider exposes a
 * temporary, read-only URI to the app selected by the user.
 */
internal object SftpShareArchivePolicy {
    const val cacheDirectory = "shared-sftp"
    const val retentionMillis = 5 * 60 * 1_000L

    fun displayName(entries: List<SftpDirectoryEntry>): String {
        val base = entries.singleOrNull()?.name?.takeIf { it.isNotBlank() }
            ?: "orbitterm-download"
        return if (base.endsWith(".zip", ignoreCase = true)) base else "$base.zip"
    }
}
