package com.orbitterm.android.feature.sftp

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import java.io.FileNotFoundException

/** Test-APK-only provider: never exposes device files or persists a document. */
class SftpCleanupTestDocumentsProvider : DocumentsProvider() {
    companion object {
        const val AUTHORITY = "com.orbitterm.android.feature.test.cleanup.documents"
        private const val DOCUMENT_ID = "isolated-cancel-target"

        @Volatile var exists = true
        @Volatile var sizeBytes = 0L
        @Volatile var flags = DocumentsContract.Document.FLAG_SUPPORTS_DELETE
        @Volatile var refuseDeletion = false
        @Volatile var deleteCalls = 0

        fun documentUri() = DocumentsContract.buildDocumentUri(AUTHORITY, DOCUMENT_ID)

        fun reset() {
            exists = true
            sizeBytes = 0L
            flags = DocumentsContract.Document.FLAG_SUPPORTS_DELETE
            refuseDeletion = false
            deleteCalls = 0
        }
    }

    override fun onCreate(): Boolean = true

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val columns = projection ?: arrayOf(
            DocumentsContract.Root.COLUMN_ROOT_ID,
            DocumentsContract.Root.COLUMN_DOCUMENT_ID,
            DocumentsContract.Root.COLUMN_TITLE,
            DocumentsContract.Root.COLUMN_MIME_TYPES,
            DocumentsContract.Root.COLUMN_FLAGS,
        )
        return MatrixCursor(columns).apply {
            addRow(columns.map { column ->
                val value: Any? = when (column) {
                    DocumentsContract.Root.COLUMN_ROOT_ID -> "isolated-root"
                    DocumentsContract.Root.COLUMN_DOCUMENT_ID -> DOCUMENT_ID
                    DocumentsContract.Root.COLUMN_TITLE -> "Isolated SFTP cleanup test"
                    DocumentsContract.Root.COLUMN_MIME_TYPES -> "application/octet-stream"
                    DocumentsContract.Root.COLUMN_FLAGS -> 0
                    else -> null
                }
                value
            }.toTypedArray())
        }
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        if (documentId != DOCUMENT_ID || !exists) throw FileNotFoundException(documentId)
        val columns = projection ?: arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_FLAGS,
        )
        return MatrixCursor(columns).apply {
            addRow(columns.map { column ->
                val value: Any? = when (column) {
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID -> DOCUMENT_ID
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME -> "isolated-target.bin"
                    DocumentsContract.Document.COLUMN_MIME_TYPE -> "application/octet-stream"
                    DocumentsContract.Document.COLUMN_SIZE -> sizeBytes
                    DocumentsContract.Document.COLUMN_FLAGS -> flags
                    else -> null
                }
                value
            }.toTypedArray())
        }
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?,
    ): Cursor = MatrixCursor(projection ?: arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID))

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor = throw FileNotFoundException("Test provider has no file stream")

    override fun deleteDocument(documentId: String) {
        if (documentId != DOCUMENT_ID || !exists) throw FileNotFoundException(documentId)
        deleteCalls++
        if (refuseDeletion) throw FileNotFoundException("Test provider refused deletion")
        exists = false
    }
}
