package com.orbitterm.android.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

sealed interface CheckedTerminalOpenResult {
    data class Opened(val terminalChannelId: Long) : CheckedTerminalOpenResult
    data class Failure(val code: String, val retryable: Boolean) : CheckedTerminalOpenResult
}

sealed interface CheckedTerminalCommandResult {
    data object Completed : CheckedTerminalCommandResult
    data class Failure(val code: String, val retryable: Boolean) : CheckedTerminalCommandResult
}

@Singleton
class CheckedTerminalNativeClient @Inject constructor() {
    fun open(baseSessionId: Long, columns: Int, rows: Int): CheckedTerminalOpenResult {
        if (!OrbitCoreBridge.isNativeLibraryAvailable) {
            return CheckedTerminalOpenResult.Failure("native_bridge_unavailable", retryable = false)
        }
        if (baseSessionId <= 0 || columns !in 1..1_000 || rows !in 1..1_000) {
            return CheckedTerminalOpenResult.Failure("invalid_terminal_request", retryable = false)
        }
        val requestId = UUID.randomUUID().toString()
        val raw = runCatching {
            OrbitCoreBridge.orbitOpenCheckedTerminal(
                baseSessionId = baseSessionId,
                cols = columns,
                rows = rows,
                requestId = requestId,
            )
        }.getOrElse {
            return CheckedTerminalOpenResult.Failure("native_bridge_failed", retryable = false)
        }
        return CheckedTerminalResponseDecoder.open(raw, requestId)
    }

    fun write(terminalChannelId: Long, data: ByteArray): CheckedTerminalCommandResult = command(
        kind = "terminal_write_completed",
        terminalChannelId = terminalChannelId,
    ) { requestId -> OrbitCoreBridge.orbitWriteCheckedTerminal(terminalChannelId, data, requestId) }

    fun resize(terminalChannelId: Long, columns: Int, rows: Int): CheckedTerminalCommandResult {
        if (columns !in 1..1_000 || rows !in 1..1_000) {
            return CheckedTerminalCommandResult.Failure("invalid_terminal_request", retryable = false)
        }
        return command(kind = "terminal_resize_completed", terminalChannelId = terminalChannelId) { requestId ->
            OrbitCoreBridge.orbitResizeCheckedTerminal(terminalChannelId, columns, rows, requestId)
        }
    }

    fun close(terminalChannelId: Long): CheckedTerminalCommandResult = command(
        kind = "terminal_close_completed",
        terminalChannelId = terminalChannelId,
        closedIsSuccess = true,
    ) { requestId -> OrbitCoreBridge.orbitCloseCheckedTerminal(terminalChannelId, requestId) }

    private fun command(
        kind: String,
        terminalChannelId: Long,
        closedIsSuccess: Boolean = false,
        call: (String) -> String,
    ): CheckedTerminalCommandResult {
        if (!OrbitCoreBridge.isNativeLibraryAvailable || terminalChannelId <= 0) {
            return CheckedTerminalCommandResult.Failure("native_bridge_unavailable", retryable = false)
        }
        val requestId = UUID.randomUUID().toString()
        val raw = runCatching { call(requestId) }.getOrNull()
            ?: return CheckedTerminalCommandResult.Failure("native_bridge_failed", retryable = false)
        return CheckedTerminalResponseDecoder.command(
            raw = raw,
            requestId = requestId,
            expectedKind = kind,
            terminalChannelId = terminalChannelId,
            closedIsSuccess = closedIsSuccess,
        )
    }
}

/**
 * The Android boundary accepts only schema-versioned JSON envelopes. This is a
 * pure decoder so correlation, late callbacks, and idempotent close handling
 * remain directly testable without loading the native library.
 */
internal object CheckedTerminalResponseDecoder {
    private val json = Json { ignoreUnknownKeys = true }
    private val idempotentCloseCodes = setOf("session_closed", "session_not_found")

    fun open(raw: String, requestId: String): CheckedTerminalOpenResult {
        val envelope = parseEnvelope(raw)
            ?: return CheckedTerminalOpenResult.Failure("invalid_native_response", retryable = false)
        if (envelope.requestId != requestId) {
            return CheckedTerminalOpenResult.Failure("uncorrelated_native_response", retryable = false)
        }
        if (envelope.kind != "terminal_channel_opened") return envelope.openFailure()
        return envelope.data.long("terminal_channel_id")?.let(CheckedTerminalOpenResult::Opened)
            ?: CheckedTerminalOpenResult.Failure("invalid_terminal_open_response", retryable = false)
    }

    fun command(
        raw: String,
        requestId: String,
        expectedKind: String,
        terminalChannelId: Long,
        closedIsSuccess: Boolean,
    ): CheckedTerminalCommandResult {
        val envelope = parseEnvelope(raw)
            ?: return CheckedTerminalCommandResult.Failure("invalid_native_response", retryable = false)
        if (envelope.requestId != requestId) {
            return CheckedTerminalCommandResult.Failure("uncorrelated_native_response", retryable = false)
        }
        if (envelope.kind == expectedKind && envelope.data.long("terminal_channel_id") == terminalChannelId) {
            return CheckedTerminalCommandResult.Completed
        }
        val failure = envelope.error?.string("code") ?: "native_operation_failed"
        if (closedIsSuccess && failure in idempotentCloseCodes) return CheckedTerminalCommandResult.Completed
        return CheckedTerminalCommandResult.Failure(
            code = failure,
            retryable = envelope.error?.get("retryable")?.jsonPrimitive?.content?.toBooleanStrictOrNull() ?: false,
        )
    }

    private fun parseEnvelope(raw: String): NativeEnvelope? = runCatching {
        val root = json.parseToJsonElement(raw).jsonObject
        if (root.long("schema_version") != 1L) return null
        NativeEnvelope(
            requestId = root.string("request_id") ?: return null,
            kind = root.string("kind") ?: return null,
            data = root["data"] as? JsonObject ?: JsonObject(emptyMap()),
            error = root["error"] as? JsonObject,
        )
    }.getOrNull()

    private data class NativeEnvelope(
        val requestId: String,
        val kind: String,
        val data: JsonObject,
        val error: JsonObject?,
    ) {
        fun openFailure() = CheckedTerminalOpenResult.Failure(
            code = error?.string("code") ?: "native_operation_failed",
            retryable = error?.get("retryable")?.jsonPrimitive?.content?.toBooleanStrictOrNull() ?: false,
        )
    }
}

private fun JsonObject.string(key: String): String? = get(key)?.jsonPrimitive?.content

private fun JsonObject.long(key: String): Long? = string(key)?.toLongOrNull()
