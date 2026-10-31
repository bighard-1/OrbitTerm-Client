package com.orbitterm.android.feature.sftp

import android.provider.DocumentsContract
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SftpCancelledTargetCleanupPolicyTest {
    private val deletable = DocumentsContract.Document.FLAG_SUPPORTS_DELETE

    private class FakeGateway(
        private val documentUri: Boolean = true,
        private val documentMetadata: CancelledDownloadDocumentMetadata? = null,
        private val deleteResult: Boolean = true,
        private val failMetadata: Boolean = false,
        private val failDelete: Boolean = false,
    ) : CancelledDownloadDocumentGateway {
        var metadataCalls = 0
        var deleteCalls = 0

        override fun isDocumentUri(): Boolean = documentUri

        override fun metadata(): CancelledDownloadDocumentMetadata? {
            metadataCalls++
            if (failMetadata) throw SecurityException("test provider denied metadata")
            return documentMetadata
        }

        override fun delete(): Boolean {
            deleteCalls++
            if (failDelete) throw SecurityException("test provider denied deletion")
            return deleteResult
        }
    }

    private fun gateway(sizeBytes: Long? = 0L, flags: Int? = deletable) =
        FakeGateway(documentMetadata = CancelledDownloadDocumentMetadata(sizeBytes, flags))

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

    @Test
    fun `nonzero and nondeletable documents never reach delete`() {
        listOf(gateway(sizeBytes = 1L), gateway(flags = 0), gateway(sizeBytes = null), gateway(flags = null))
            .forEach { target ->
                assertFalse(removeEmptyCreatedDownloadDocument(true, target))
                assertEquals(1, target.metadataCalls)
                assertEquals(0, target.deleteCalls)
            }
    }

    @Test
    fun `uncreated or non-document targets never reach delete`() {
        val notCreated = gateway()
        assertFalse(removeEmptyCreatedDownloadDocument(false, notCreated))
        assertEquals(0, notCreated.metadataCalls)
        assertEquals(0, notCreated.deleteCalls)

        val notDocument = FakeGateway(documentUri = false)
        assertFalse(removeEmptyCreatedDownloadDocument(true, notDocument))
        assertEquals(0, notDocument.metadataCalls)
        assertEquals(0, notDocument.deleteCalls)
    }

    @Test
    fun `provider errors and refusal fail closed`() {
        val missingMetadata = FakeGateway()
        assertFalse(removeEmptyCreatedDownloadDocument(true, missingMetadata))
        assertEquals(0, missingMetadata.deleteCalls)

        val deniedMetadata = FakeGateway(failMetadata = true)
        assertFalse(removeEmptyCreatedDownloadDocument(true, deniedMetadata))
        assertEquals(0, deniedMetadata.deleteCalls)

        val refusedDeletion = FakeGateway(
            documentMetadata = CancelledDownloadDocumentMetadata(0L, deletable),
            deleteResult = false,
        )
        assertFalse(removeEmptyCreatedDownloadDocument(true, refusedDeletion))
        assertEquals(1, refusedDeletion.deleteCalls)

        val deniedDeletion = FakeGateway(
            documentMetadata = CancelledDownloadDocumentMetadata(0L, deletable),
            failDelete = true,
        )
        assertFalse(removeEmptyCreatedDownloadDocument(true, deniedDeletion))
        assertEquals(1, deniedDeletion.deleteCalls)
    }

    @Test
    fun `only eligible empty new document invokes delete`() {
        val target = gateway()
        assertTrue(removeEmptyCreatedDownloadDocument(true, target))
        assertEquals(1, target.metadataCalls)
        assertEquals(1, target.deleteCalls)
    }
}
