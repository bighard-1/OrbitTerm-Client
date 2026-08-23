package com.orbitterm.android.feature.sftp

import com.orbitterm.android.core.SftpDirectoryEntry

internal sealed interface SftpInAppDocumentDecision {
    data object Allowed : SftpInAppDocumentDecision
    data object Directory : SftpInAppDocumentDecision
    data class TooLarge(val size: Long) : SftpInAppDocumentDecision
}

/**
 * Application previews are intentionally bounded. UTF-8 validity is checked
 * by the native layer after a size-limited read, so extensionless configs and
 * logs remain editable without guessing from a filename.
 */
internal object SftpInAppDocumentPolicy {
    const val MAX_TEXT_BYTES: Long = 2L * 1024L * 1024L

    fun evaluate(entry: SftpDirectoryEntry): SftpInAppDocumentDecision = when {
        entry.isDirectory -> SftpInAppDocumentDecision.Directory
        entry.size < 0L || entry.size > MAX_TEXT_BYTES -> SftpInAppDocumentDecision.TooLarge(entry.size)
        else -> SftpInAppDocumentDecision.Allowed
    }

    fun hasUnsavedChanges(isEditing: Boolean, original: String, draft: String): Boolean =
        isEditing && original != draft
}

enum class SftpLineEnding(val label: String) {
    LF("LF"),
    CRLF("CRLF"),
    CR("CR"),
}

data class SftpTextFormat(
    val lineEnding: SftpLineEnding,
    val hasUtf8Bom: Boolean,
) {
    val displayLabel: String
        get() = "UTF-8${if (hasUtf8Bom) " BOM" else ""} · ${lineEnding.label}"

    fun serialize(editorContent: String): String {
        val normalized = editorContent.replace("\r\n", "\n").replace('\r', '\n')
        val body = when (lineEnding) {
            SftpLineEnding.LF -> normalized
            SftpLineEnding.CRLF -> normalized.replace("\n", "\r\n")
            SftpLineEnding.CR -> normalized.replace('\n', '\r')
        }
        return if (hasUtf8Bom) "\uFEFF$body" else body
    }

    companion object {
        fun detectAndNormalize(source: String): Pair<String, SftpTextFormat> {
            val hasBom = source.startsWith('\uFEFF')
            val body = if (hasBom) source.drop(1) else source
            val crlfCount = body.windowed(2).count { it == "\r\n" }
            val withoutCrlf = body.replace("\r\n", "")
            val crCount = withoutCrlf.count { it == '\r' }
            val lfCount = withoutCrlf.count { it == '\n' }
            val ending = when {
                crlfCount > 0 && crlfCount >= maxOf(crCount, lfCount) -> SftpLineEnding.CRLF
                crCount > lfCount -> SftpLineEnding.CR
                else -> SftpLineEnding.LF
            }
            val normalized = body.replace("\r\n", "\n").replace('\r', '\n')
            return normalized to SftpTextFormat(ending, hasBom)
        }
    }
}
