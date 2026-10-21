package com.orbitterm.android.feature.sftp

import android.provider.DocumentsContract
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

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
}
