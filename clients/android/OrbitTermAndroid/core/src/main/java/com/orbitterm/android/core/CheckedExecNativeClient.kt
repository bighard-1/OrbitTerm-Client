package com.orbitterm.android.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

sealed interface CheckedExecResult {
    data class Completed(val exitStatus: Int, val stdout: String, val stderr: String) : CheckedExecResult
    data class Failure(val code: String) : CheckedExecResult
}

/** Executes bounded commands only through an active HostKey-verified SSH base session. */
@Singleton
class CheckedExecNativeClient @Inject constructor() {
    private val json = Json { ignoreUnknownKeys = true }

    fun execute(baseSessionId: Long, command: String, timeoutSeconds: Int = 30): CheckedExecResult {
        if (!OrbitCoreBridge.isNativeLibraryAvailable || baseSessionId <= 0 || command.isBlank()) {
            return CheckedExecResult.Failure("invalid_exec_request")
        }
        val raw = runCatching {
            OrbitCoreBridge.orbitExecChecked(baseSessionId, command, timeoutSeconds, 65_536, 32_768, UUID.randomUUID().toString())
        }.getOrElse { return CheckedExecResult.Failure("native_bridge_failed") }
        val root = runCatching { json.parseToJsonElement(raw).jsonObject }.getOrNull()
            ?: return CheckedExecResult.Failure("invalid_native_response")
        if (root["kind"]?.jsonPrimitive?.content != "exec_result") {
            return CheckedExecResult.Failure(root["error"]?.jsonObject?.get("code")?.jsonPrimitive?.content ?: "native_operation_failed")
        }
        val data = root["data"]?.jsonObject ?: return CheckedExecResult.Failure("invalid_exec_response")
        return CheckedExecResult.Completed(
            data["exit_status"]?.jsonPrimitive?.content?.toIntOrNull() ?: 0,
            data["stdout"]?.jsonPrimitive?.content.orEmpty(),
            data["stderr"]?.jsonPrimitive?.content.orEmpty(),
        )
    }
}
