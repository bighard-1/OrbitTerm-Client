package com.orbitterm.android.feature.sftp

import com.orbitterm.android.core.SftpDirectoryEntry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SftpShareArchivePolicyTest {
    @Test
    fun `single archive keeps its existing zip suffix`() {
        assertEquals("logs.zip", SftpShareArchivePolicy.displayName(listOf(entry("logs.zip"))))
    }

    @Test
    fun `single item gets a zip suffix and multi selection gets a neutral name`() {
        assertEquals("logs.zip", SftpShareArchivePolicy.displayName(listOf(entry("logs"))))
        assertEquals(
            "orbitterm-download.zip",
            SftpShareArchivePolicy.displayName(listOf(entry("logs"), entry("config"))),
        )
    }

    @Test
    fun `shared archives have a short bounded retention window`() {
        assertTrue(SftpShareArchivePolicy.retentionMillis in 1_000L..(10 * 60 * 1_000L))
        assertEquals("shared-sftp", SftpShareArchivePolicy.cacheDirectory)
    }

    private fun entry(name: String) = SftpDirectoryEntry(
        name = name,
        size = 0,
        permissions = "-rw-r--r--",
        permissionsOctal = 420,
        modifiedAtUnix = 0,
    )
}
