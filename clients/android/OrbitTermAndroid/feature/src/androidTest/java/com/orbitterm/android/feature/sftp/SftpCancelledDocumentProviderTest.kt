package com.orbitterm.android.feature.sftp

import android.provider.DocumentsContract
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.orbitterm.android.core.CheckedSftpTransferResult
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class SftpCancelledDocumentProviderTest {
    private val provider = SftpCleanupTestDocumentsProvider
    private val context get() = InstrumentationRegistry.getInstrumentation().context
    private val destination get() = provider.documentUri()

    @Before fun setUp() = provider.reset()
    @After fun tearDown() = provider.reset()

    @Test fun nonzeroDocumentIsPreserved() {
        provider.sizeBytes = 7L
        assertTrue(DocumentsContract.isDocumentUri(context, destination))
        assertFalse(removeEmptyCreatedDownloadDocument(context, destination))
        assertTrue(provider.exists)
        assertEquals(0, provider.deleteCalls)
    }

    @Test fun documentWithoutDeleteFlagIsPreserved() {
        provider.flags = 0
        assertFalse(removeEmptyCreatedDownloadDocument(context, destination))
        assertTrue(provider.exists)
        assertEquals(0, provider.deleteCalls)
    }

    @Test fun documentWithUnknownSizeIsPreserved() {
        provider.sizeBytes = null
        assertFalse(removeEmptyCreatedDownloadDocument(context, destination))
        assertTrue(provider.exists)
        assertEquals(0, provider.deleteCalls)
    }

    @Test fun documentWithUnknownDeleteCapabilityIsPreserved() {
        provider.flags = null
        assertFalse(removeEmptyCreatedDownloadDocument(context, destination))
        assertTrue(provider.exists)
        assertEquals(0, provider.deleteCalls)
    }

    @Test fun providerMetadataRefusalPreservesDocument() {
        provider.refuseMetadata = true
        assertFalse(removeEmptyCreatedDownloadDocument(context, destination))
        assertTrue(provider.exists)
        assertEquals(0, provider.deleteCalls)
    }

    @Test fun pickerCreatedUnknownSizeDocumentIsPreserved() {
        val selected = createPickerDocument("qa-unknown-size-instrumented.zip")
        assertFalse(removeEmptyCreatedDownloadDocument(context, selected))
        assertPickerDocumentExists(selected)
        assertEquals(0, provider.deleteCalls)
    }

    @Test fun pickerCreatedDocumentWithoutDeleteFlagIsPreserved() {
        val selected = createPickerDocument("qa-no-delete-instrumented.zip")
        assertFalse(removeEmptyCreatedDownloadDocument(context, selected))
        assertPickerDocumentExists(selected)
        assertEquals(0, provider.deleteCalls)
    }

    @Test fun pickerCreatedDocumentRefusingDeleteIsPreserved() {
        val selected = createPickerDocument("qa-refuse-delete-instrumented.zip")
        assertFalse(removeEmptyCreatedDownloadDocument(context, selected))
        assertPickerDocumentExists(selected)
        assertEquals(1, provider.deleteCalls)
    }

    @Test fun providerRefusalPreservesDocumentAndReturnsFailure() {
        provider.refuseDeletion = true
        assertFalse(removeEmptyCreatedDownloadDocument(context, destination))
        assertTrue(provider.exists)
        assertEquals(1, provider.deleteCalls)
    }

    @Test fun onlyEligibleEmptyDocumentIsDeleted() {
        assertTrue(removeEmptyCreatedDownloadDocument(context, destination))
        assertFalse(provider.exists)
        assertEquals(1, provider.deleteCalls)
    }

    @Test fun providerRefusesOutputStreamWithoutDeletingSelectedTarget() {
        val staging = File.createTempFile("sftp-provider-refusal-", ".bin", context.cacheDir)
        try {
            staging.writeBytes(byteArrayOf(1, 2, 3, 4))
            val result = copyDownloadedStagingToDestination(
                staging,
                CheckedSftpTransferResult.Completed(4),
            ) { context.contentResolver.openOutputStream(destination) }
            assertEquals(CheckedSftpTransferResult.Failure("destination_unwritable"), result)
            assertTrue(provider.exists)
            assertEquals(0, provider.deleteCalls)
        } finally {
            staging.delete()
        }
    }

    private fun createPickerDocument(name: String) =
        requireNotNull(DocumentsContract.createDocument(context.contentResolver, provider.rootUri(), "application/zip", name))

    private fun assertPickerDocumentExists(uri: android.net.Uri) {
        assertTrue(
            context.contentResolver.query(
                uri,
                arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                null,
                null,
                null,
            )?.use { it.moveToFirst() } == true,
        )
    }
}
