package com.orbitterm.android.feature.sftp

import android.provider.DocumentsContract
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SftpCancelledTargetCleanupPolicyTest {
    private val deletable = DocumentsContract.Document.FLAG_SUPPORTS_DELETE

    @Test
    fun `only a new empty deletable picker document is eligible`() {
        assertTrue(shouldRemoveEmptyCancelledDownloadTarget(true, true, 0L, deletable))
        assertFalse(shouldRemoveEmptyCancelledDownloadTarget(false, true, 0L, deletable))
        assertFalse(shouldRemoveEmptyCancelledDownloadTarget(true, false, 0L, deletable))
        assertFalse(shouldRemoveEmptyCancelledDownloadTarget(true, true, 1L, deletable))
        assertFalse(shouldRemoveEmptyCancelledDownloadTarget(true, true, null, deletable))
        assertFalse(shouldRemoveEmptyCancelledDownloadTarget(true, true, 0L, null))
        assertFalse(shouldRemoveEmptyCancelledDownloadTarget(true, true, 0L, 0))
    }
}
