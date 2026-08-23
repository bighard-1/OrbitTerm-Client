package com.orbitterm.android.feature.sftp

import com.orbitterm.android.core.SftpDirectoryEntry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SftpInAppDocumentPolicyTest {
    @Test
    fun `extensionless text sized file is allowed`() {
        assertEquals(SftpInAppDocumentDecision.Allowed, SftpInAppDocumentPolicy.evaluate(file("authorized_keys", 512)))
    }

    @Test
    fun `directory is never treated as a document`() {
        assertEquals(SftpInAppDocumentDecision.Directory, SftpInAppDocumentPolicy.evaluate(file("config", 0, directory = true)))
    }

    @Test
    fun `oversized file is rejected before native read`() {
        val decision = SftpInAppDocumentPolicy.evaluate(
            file("large.log", SftpInAppDocumentPolicy.MAX_TEXT_BYTES + 1),
        )
        assertTrue(decision is SftpInAppDocumentDecision.TooLarge)
    }

    @Test
    fun `editing changed content requires discard confirmation`() {
        assertTrue(SftpInAppDocumentPolicy.hasUnsavedChanges(true, "before", "after"))
        assertEquals(false, SftpInAppDocumentPolicy.hasUnsavedChanges(true, "same", "same"))
        assertEquals(false, SftpInAppDocumentPolicy.hasUnsavedChanges(false, "before", "after"))
    }

    @Test
    fun `editor preserves utf8 bom and crlf when saving`() {
        val (normalized, format) = SftpTextFormat.detectAndNormalize("\uFEFFfirst\r\nsecond\r\n")
        assertEquals("first\nsecond\n", normalized)
        assertEquals(SftpLineEnding.CRLF, format.lineEnding)
        assertTrue(format.hasUtf8Bom)
        assertEquals("\uFEFFfirst\r\nchanged\r\n", format.serialize("first\nchanged\n"))
    }

    @Test
    fun `editor preserves legacy cr without corrupting line endings`() {
        val (normalized, format) = SftpTextFormat.detectAndNormalize("first\rsecond\r")
        assertEquals("first\nsecond\n", normalized)
        assertEquals(SftpLineEnding.CR, format.lineEnding)
        assertEquals("first\rsecond\r", format.serialize(normalized))
    }

    @Test
    fun `visual wrapping does not introduce line endings while explicit returns do`() {
        val format = SftpTextFormat(SftpLineEnding.CRLF, hasUtf8Bom = false)
        val visuallyWrappedLongLine = "x".repeat(240)
        assertEquals(visuallyWrappedLongLine, format.serialize(visuallyWrappedLongLine))
        assertEquals("first\r\nsecond", format.serialize("first\nsecond"))
    }

    private fun file(name: String, size: Long, directory: Boolean = false) = SftpDirectoryEntry(
        name = name,
        size = size,
        permissions = if (directory) "drwxr-xr-x" else "-rw-r--r--",
        permissionsOctal = if (directory) 16877 else 33188,
        modifiedAtUnix = 1,
    )
}
