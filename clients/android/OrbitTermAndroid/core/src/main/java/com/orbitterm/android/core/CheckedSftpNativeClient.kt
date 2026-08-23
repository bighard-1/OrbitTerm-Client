package com.orbitterm.android.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

data class SftpDirectoryEntry(
    val name: String,
    val size: Long,
    val permissions: String,
    val permissionsOctal: Int,
    val modifiedAtUnix: Long,
) {
    val isDirectory: Boolean get() = permissions.startsWith('d')
}

sealed interface CheckedSftpOpenResult {
    data class Opened(val sftpSessionId: Long, val homePath: String) : CheckedSftpOpenResult
    data class Failure(val code: String, val retryable: Boolean) : CheckedSftpOpenResult
}

sealed interface CheckedSftpListResult {
    data class Listed(val path: String, val entries: List<SftpDirectoryEntry>) : CheckedSftpListResult
    data class Failure(val code: String, val retryable: Boolean) : CheckedSftpListResult
}

sealed interface CheckedSftpMutationResult {
    data object Completed : CheckedSftpMutationResult
    data class Failure(val code: String, val retryable: Boolean) : CheckedSftpMutationResult
}

sealed interface CheckedSftpTextResult {
    data class Read(val content: String) : CheckedSftpTextResult
    data class Failure(val code: String, val retryable: Boolean) : CheckedSftpTextResult
}

sealed interface CheckedSftpTransferResult {
    data class Completed(val byteLength: Long) : CheckedSftpTransferResult
    data class Failure(val code: String) : CheckedSftpTransferResult
}

/** Calls only the additive checked SFTP ABI, which requires a verified base SSH session. */
@Singleton
class CheckedSftpNativeClient @Inject constructor() {
    private val json = Json { ignoreUnknownKeys = true }

    fun open(baseSessionId: Long): CheckedSftpOpenResult {
        if (!OrbitCoreBridge.isNativeLibraryAvailable || baseSessionId <= 0) {
            return CheckedSftpOpenResult.Failure("native_bridge_unavailable", retryable = false)
        }
        val requestId = UUID.randomUUID().toString()
        val raw = runCatching {
            OrbitCoreBridge.orbitOpenCheckedSftp(baseSessionId, requestId)
        }.getOrElse { return CheckedSftpOpenResult.Failure("native_bridge_failed", retryable = false) }
        val envelope = parseEnvelope(raw, requestId)
            ?: return CheckedSftpOpenResult.Failure("uncorrelated_native_response", retryable = false)
        if (envelope.kind != "sftp_channel_opened") return envelope.openFailure()
        val sessionId = envelope.data.long("sftp_session_id")
            ?: return CheckedSftpOpenResult.Failure("invalid_sftp_open_response", retryable = false)
        val homePath = envelope.data.string("home_path")?.takeIf(String::isSafeRemotePath) ?: "/"
        return CheckedSftpOpenResult.Opened(sessionId, homePath)
    }

    fun list(sftpSessionId: Long, path: String): CheckedSftpListResult {
        if (!OrbitCoreBridge.isNativeLibraryAvailable || sftpSessionId <= 0 || !path.isSafeRemotePath()) {
            return CheckedSftpListResult.Failure("invalid_sftp_list_request", retryable = false)
        }
        val requestId = UUID.randomUUID().toString()
        val raw = runCatching {
            OrbitCoreBridge.orbitListCheckedSftp(sftpSessionId, path, requestId)
        }.getOrElse { return CheckedSftpListResult.Failure("native_bridge_failed", retryable = false) }
        val envelope = parseEnvelope(raw, requestId)
            ?: return CheckedSftpListResult.Failure("uncorrelated_native_response", retryable = false)
        if (envelope.kind != "sftp_directory_list") return envelope.listFailure()
        val listedPath = envelope.data.string("path") ?: return CheckedSftpListResult.Failure(
            "invalid_sftp_list_response",
            retryable = false,
        )
        val entries = (envelope.data["entries"] as? JsonArray)?.mapNotNull(::parseEntry)
            ?: return CheckedSftpListResult.Failure("invalid_sftp_list_response", retryable = false)
        return CheckedSftpListResult.Listed(listedPath, entries)
    }

    fun createDirectory(sftpSessionId: Long, path: String): CheckedSftpMutationResult = mutate { requestId ->
        OrbitCoreBridge.orbitCreateCheckedSftpDirectory(sftpSessionId, path, requestId)
    }

    fun readText(sftpSessionId: Long, path: String): CheckedSftpTextResult {
        if (!OrbitCoreBridge.isNativeLibraryAvailable || sftpSessionId <= 0 || !path.isSafeRemotePath()) {
            return CheckedSftpTextResult.Failure("invalid_sftp_read_request", retryable = false)
        }
        val requestId = UUID.randomUUID().toString()
        val raw = runCatching {
            OrbitCoreBridge.orbitReadCheckedSftpText(sftpSessionId, path, requestId)
        }.getOrElse { return CheckedSftpTextResult.Failure("native_bridge_failed", retryable = false) }
        val envelope = parseEnvelope(raw, requestId)
            ?: return CheckedSftpTextResult.Failure("uncorrelated_native_response", retryable = false)
        if (envelope.kind != "sftp_text_file") {
            return CheckedSftpTextResult.Failure(
                envelope.error?.string("code") ?: "native_operation_failed",
                envelope.error?.string("retryable")?.toBooleanStrictOrNull() ?: false,
            )
        }
        return envelope.data.string("content")?.let(CheckedSftpTextResult::Read)
            ?: CheckedSftpTextResult.Failure("invalid_sftp_text_response", retryable = false)
    }

    fun writeText(sftpSessionId: Long, path: String, content: String, entry: SftpDirectoryEntry): CheckedSftpMutationResult = mutate { requestId ->
        OrbitCoreBridge.orbitWriteCheckedSftpText(
            sftpSessionId, path, content.toByteArray(Charsets.UTF_8), entry.size,
            entry.permissionsOctal, entry.modifiedAtUnix, entry.isDirectory, requestId,
        )
    }

    fun createFile(sftpSessionId: Long, path: String): CheckedSftpMutationResult = mutate { requestId ->
        OrbitCoreBridge.orbitCreateCheckedSftpFile(sftpSessionId, path, requestId)
    }

    fun rename(sftpSessionId: Long, oldPath: String, newPath: String, entry: SftpDirectoryEntry): CheckedSftpMutationResult = mutate { requestId ->
        OrbitCoreBridge.orbitRenameCheckedSftpEntry(
            sftpSessionId, oldPath, newPath, entry.size, entry.permissionsOctal,
            entry.modifiedAtUnix, entry.isDirectory, requestId,
        )
    }

    fun remove(sftpSessionId: Long, path: String, entry: SftpDirectoryEntry): CheckedSftpMutationResult = mutate { requestId ->
        OrbitCoreBridge.orbitRemoveCheckedSftpEntry(
            sftpSessionId, path, entry.size, entry.permissionsOctal,
            entry.modifiedAtUnix, entry.isDirectory, requestId,
        )
    }

    fun chmod(sftpSessionId: Long, path: String, mode: Int, entry: SftpDirectoryEntry): CheckedSftpMutationResult = mutate { requestId ->
        OrbitCoreBridge.orbitChmodCheckedSftpEntry(
            sftpSessionId, path, mode, entry.size, entry.permissionsOctal,
            entry.modifiedAtUnix, entry.isDirectory, requestId,
        )
    }

    fun upload(
        sftpSessionId: Long,
        localPath: String,
        remotePath: String,
        requestId: String = UUID.randomUUID().toString(),
    ): CheckedSftpTransferResult = transfer(requestId) {
        OrbitCoreBridge.orbitUploadCheckedSftpFile(sftpSessionId, localPath, remotePath, requestId)
    }

    fun download(
        sftpSessionId: Long,
        remotePath: String,
        localPath: String,
        requestId: String = UUID.randomUUID().toString(),
    ): CheckedSftpTransferResult = transfer(requestId) {
        OrbitCoreBridge.orbitDownloadCheckedSftpFile(sftpSessionId, remotePath, localPath, requestId)
    }

    fun cancelTransfer(requestId: String): Boolean {
        if (!OrbitCoreBridge.isNativeLibraryAvailable || requestId.isBlank()) return false
        val raw = runCatching { OrbitCoreBridge.orbitCancelCheckedSftpTransfer(requestId) }.getOrNull() ?: return false
        val envelope = parseEnvelope(raw, requestId) ?: return false
        return envelope.kind == "sftp_transfer_cancelled" && envelope.data.string("cancelled") == "true"
    }

    private fun mutate(call: (String) -> String): CheckedSftpMutationResult {
        if (!OrbitCoreBridge.isNativeLibraryAvailable) {
            return CheckedSftpMutationResult.Failure("native_bridge_unavailable", retryable = false)
        }
        val requestId = UUID.randomUUID().toString()
        val raw = runCatching { call(requestId) }.getOrElse {
            return CheckedSftpMutationResult.Failure("native_bridge_failed", retryable = false)
        }
        val envelope = parseEnvelope(raw, requestId)
            ?: return CheckedSftpMutationResult.Failure("uncorrelated_native_response", retryable = false)
        return if (envelope.kind == "sftp_mutation_completed") {
            CheckedSftpMutationResult.Completed
        } else {
            CheckedSftpMutationResult.Failure(
                code = envelope.error?.string("code") ?: "native_operation_failed",
                retryable = envelope.error?.string("retryable")?.toBooleanStrictOrNull() ?: false,
            )
        }
    }

    private fun transfer(requestId: String, call: () -> String): CheckedSftpTransferResult {
        if (!OrbitCoreBridge.isNativeLibraryAvailable) return CheckedSftpTransferResult.Failure("native_bridge_unavailable")
        val raw = runCatching(call).getOrElse { return CheckedSftpTransferResult.Failure("native_bridge_failed") }
        val envelope = parseEnvelope(raw, requestId) ?: return CheckedSftpTransferResult.Failure("uncorrelated_native_response")
        val bytes = envelope.data.long("byte_length")
        return if (envelope.kind == "sftp_upload_completed" || envelope.kind == "sftp_download_completed") {
            CheckedSftpTransferResult.Completed(bytes ?: 0)
        } else CheckedSftpTransferResult.Failure(envelope.error?.string("code") ?: "native_operation_failed")
    }

    private fun parseEnvelope(raw: String, expectedRequestId: String): NativeEnvelope? = runCatching {
        val root = json.parseToJsonElement(raw).jsonObject
        if (root.long("schema_version") != 1L || root.string("request_id") != expectedRequestId) return null
        NativeEnvelope(
            kind = root.string("kind") ?: return null,
            data = root["data"] as? JsonObject ?: JsonObject(emptyMap()),
            error = root["error"] as? JsonObject,
        )
    }.getOrNull()

    private fun parseEntry(value: kotlinx.serialization.json.JsonElement): SftpDirectoryEntry? {
        val entry = value as? JsonObject ?: return null
        return SftpDirectoryEntry(
            name = entry.string("name") ?: return null,
            size = entry.long("size") ?: return null,
            permissions = entry.string("permissions") ?: return null,
            permissionsOctal = entry.long("permissions_octal")
                ?.takeIf { it in 0..Int.MAX_VALUE }
                ?.toInt()
                ?: return null,
            modifiedAtUnix = entry.long("modified_at_unix") ?: return null,
        )
    }

    private data class NativeEnvelope(
        val kind: String,
        val data: JsonObject,
        val error: JsonObject?,
    ) {
        fun openFailure() = CheckedSftpOpenResult.Failure(
            code = error?.string("code") ?: "native_operation_failed",
            retryable = error?.string("retryable")?.toBooleanStrictOrNull() ?: false,
        )

        fun listFailure() = CheckedSftpListResult.Failure(
            code = error?.string("code") ?: "native_operation_failed",
            retryable = error?.string("retryable")?.toBooleanStrictOrNull() ?: false,
        )
    }
}

private fun JsonObject.string(key: String): String? = get(key)?.jsonPrimitive?.content

private fun JsonObject.long(key: String): Long? = string(key)?.toLongOrNull()

private fun String.isSafeRemotePath(): Boolean = startsWith('/') && !contains('\\') && split('/').none { it == ".." }
