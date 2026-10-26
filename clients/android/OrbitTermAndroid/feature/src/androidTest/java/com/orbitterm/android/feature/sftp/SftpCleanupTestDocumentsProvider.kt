package com.orbitterm.android.feature.sftp

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import java.io.FileNotFoundException
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap

/** Test-APK-only provider: never exposes device files or persists a document. */
class SftpCleanupTestDocumentsProvider : DocumentsProvider() {
    companion object {
        const val AUTHORITY = "com.orbitterm.android.feature.test.cleanup.documents"
        private const val DOCUMENT_ID = "isolated-cancel-target"
        private const val ROOT_DOCUMENT_ID = "isolated-root-document"
        private val pickerDocuments = Collections.synchronizedSet(mutableSetOf<String>())
        private val pickerWrittenSizes = ConcurrentHashMap<String, Long>()

        @Volatile var exists = true
        @Volatile var sizeBytes: Long? = 0L
        @Volatile var flags: Int? = DocumentsContract.Document.FLAG_SUPPORTS_DELETE
        @Volatile var refuseMetadata = false
        @Volatile var refuseDeletion = false
        @Volatile var deleteCalls = 0

        fun documentUri() = DocumentsContract.buildDocumentUri(AUTHORITY, DOCUMENT_ID)
        fun rootUri() = DocumentsContract.buildDocumentUri(AUTHORITY, ROOT_DOCUMENT_ID)

        fun reset() {
            exists = true
            sizeBytes = 0L
            flags = DocumentsContract.Document.FLAG_SUPPORTS_DELETE
            refuseMetadata = false
            refuseDeletion = false
            deleteCalls = 0
            pickerDocuments.clear()
            pickerWrittenSizes.clear()
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
                    DocumentsContract.Root.COLUMN_DOCUMENT_ID -> ROOT_DOCUMENT_ID
                    DocumentsContract.Root.COLUMN_TITLE -> "OrbitTerm SAF QA (virtual)"
                    DocumentsContract.Root.COLUMN_MIME_TYPES -> "application/zip"
                    DocumentsContract.Root.COLUMN_FLAGS -> DocumentsContract.Root.FLAG_SUPPORTS_CREATE or
                        DocumentsContract.Root.FLAG_LOCAL_ONLY
                    else -> null
                }
                value
            }.toTypedArray())
        }
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        if (documentId != ROOT_DOCUMENT_ID &&
            !((documentId == DOCUMENT_ID && exists) || pickerDocuments.contains(documentId))
        ) throw FileNotFoundException(documentId)
        if (refuseMetadata) throw SecurityException("Test provider refused metadata")
        val columns = projection ?: arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_FLAGS,
        )
        return MatrixCursor(columns).apply { addRow(documentRow(documentId, columns)) }
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        if (parentDocumentId != ROOT_DOCUMENT_ID) throw FileNotFoundException(parentDocumentId)
        val columns = projection ?: arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_FLAGS,
        )
        return MatrixCursor(columns).apply {
            pickerDocuments.toList().sorted().forEach { addRow(documentRow(it, columns)) }
        }
    }

    override fun createDocument(parentDocumentId: String, mimeType: String, displayName: String): String {
        if (parentDocumentId != ROOT_DOCUMENT_ID || mimeType != "application/zip" ||
            !displayName.startsWith("qa-") || !displayName.endsWith(".zip") ||
            displayName.contains('/')
        ) throw FileNotFoundException("Only virtual QA ZIP targets are supported")
        if (!pickerDocuments.add(displayName)) throw FileNotFoundException("Virtual target already exists")
        return displayName
    }

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor {
        if (!pickerDocuments.contains(documentId) || !documentId.contains("write-fail") ||
            !mode.contains('w')
        ) throw FileNotFoundException("Test provider has no file stream")
        val (reader, writer) = ParcelFileDescriptor.createReliablePipe()
        Thread({
            try {
                ParcelFileDescriptor.AutoCloseInputStream(reader).use { input ->
                    val received = input.read(ByteArray(4096))
                    if (received > 0) pickerWrittenSizes[documentId] = received.toLong()
                    reader.closeWithError("Injected virtual QA write failure")
                }
            } catch (_: Exception) {
                reader.close()
            }
        }, "qa-saf-write-failure").apply { isDaemon = true; start() }
        return writer
    }

    override fun deleteDocument(documentId: String) {
        if (documentId != DOCUMENT_ID && !pickerDocuments.contains(documentId)) {
            throw FileNotFoundException(documentId)
        }
        deleteCalls++
        if (refuseDeletion || documentId.contains("refuse-delete")) {
            throw FileNotFoundException("Test provider refused deletion")
        }
        if (documentId == DOCUMENT_ID) exists = false else pickerDocuments.remove(documentId)
    }

    private fun documentRow(documentId: String, columns: Array<out String>): Array<Any?> =
        columns.map { column ->
            when (column) {
                DocumentsContract.Document.COLUMN_DOCUMENT_ID -> documentId
                DocumentsContract.Document.COLUMN_DISPLAY_NAME -> when (documentId) {
                    ROOT_DOCUMENT_ID -> "OrbitTerm SAF QA (virtual)"
                    DOCUMENT_ID -> "isolated-target.bin"
                    else -> documentId
                }
                DocumentsContract.Document.COLUMN_MIME_TYPE -> when (documentId) {
                    ROOT_DOCUMENT_ID -> DocumentsContract.Document.MIME_TYPE_DIR
                    DOCUMENT_ID -> "application/octet-stream"
                    else -> "application/zip"
                }
                DocumentsContract.Document.COLUMN_SIZE -> when {
                    documentId == ROOT_DOCUMENT_ID -> null
                    documentId == DOCUMENT_ID -> sizeBytes
                    documentId.contains("unknown-size") -> null
                    documentId.contains("write-fail") -> pickerWrittenSizes[documentId] ?: 0L
                    else -> 0L
                }
                DocumentsContract.Document.COLUMN_FLAGS -> when {
                    documentId == ROOT_DOCUMENT_ID -> DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
                    documentId == DOCUMENT_ID -> flags
                    documentId.contains("no-delete") -> 0
                    else -> DocumentsContract.Document.FLAG_SUPPORTS_DELETE
                }
                else -> null
            }
        }.toTypedArray()
}
