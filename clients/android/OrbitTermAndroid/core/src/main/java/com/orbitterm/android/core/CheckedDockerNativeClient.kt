package com.orbitterm.android.core

import com.orbitterm.android.domain.performance.RuntimeResourceBudget
import com.orbitterm.android.domain.performance.retainUtf8Tail
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

data class DockerContainer(val id: String, val name: String, val image: String, val state: String, val status: String)
data class DockerStats(
    val id: String,
    val cpuPercent: Double,
    val memoryPercent: Double,
    val memoryUsage: String,
    val networkIo: String,
    val blockIo: String,
    val pids: Long,
)

sealed interface CheckedDockerResult {
    data class Listed(val containers: List<DockerContainer>) : CheckedDockerResult
    data class Logs(val content: String, val wasTruncated: Boolean) : CheckedDockerResult
    data class Stats(val items: List<DockerStats>) : CheckedDockerResult
    data object Completed : CheckedDockerResult
    data class Failure(val code: String) : CheckedDockerResult
}

/** Uses only the checked Docker ABI, which rejects unverified or closed SSH sessions. */
@Singleton
class CheckedDockerNativeClient @Inject constructor() {
    private val json = Json { ignoreUnknownKeys = true }

    fun list(baseSessionId: Long): CheckedDockerResult = call { requestId ->
        OrbitCoreBridge.orbitListCheckedDocker(baseSessionId, requestId)
    }.let { envelope ->
        if (envelope.kind != "docker_containers") return@let envelope.failure()
        val containers = (envelope.data["containers"] as? JsonArray)?.mapNotNull { item ->
            val value = item as? JsonObject ?: return@mapNotNull null
            DockerContainer(
                id = value.text("id") ?: return@mapNotNull null,
                name = value.text("name") ?: return@mapNotNull null,
                image = value.text("image") ?: return@mapNotNull null,
                state = value.text("state") ?: return@mapNotNull null,
                status = value.text("status") ?: return@mapNotNull null,
            )
        } ?: return CheckedDockerResult.Failure("invalid_docker_list_response")
        CheckedDockerResult.Listed(containers)
    }

    fun action(baseSessionId: Long, containerId: String, action: String): CheckedDockerResult {
        if (action !in ACTIONS) return CheckedDockerResult.Failure("invalid_docker_action")
        return call { requestId ->
            OrbitCoreBridge.orbitDockerAction(baseSessionId, containerId, action, requestId)
        }.let { if (it.kind == "docker_action_result") CheckedDockerResult.Completed else it.failure() }
    }

    fun logs(baseSessionId: Long, containerId: String, tail: Int = 500): CheckedDockerResult = call { requestId ->
        OrbitCoreBridge.orbitDockerLogs(baseSessionId, containerId, tail, requestId)
    }.let { envelope ->
        if (envelope.kind != "docker_logs") return@let envelope.failure()
        envelope.data.text("logs")?.let { rawLogs ->
            rawLogs.retainUtf8Tail(RuntimeResourceBudget.DOCKER_LOG_MAX_UI_BYTES).let {
                CheckedDockerResult.Logs(content = it.content, wasTruncated = it.wasTruncated)
            }
        } ?: CheckedDockerResult.Failure("invalid_docker_logs_response")
    }

    fun stats(baseSessionId: Long): CheckedDockerResult = call { requestId ->
        OrbitCoreBridge.orbitStatsCheckedDocker(baseSessionId, requestId)
    }.let { envelope ->
        if (envelope.kind != "docker_stats") return@let envelope.failure()
        val items = (envelope.data["stats"] as? JsonArray)?.mapNotNull { item ->
            val value = item as? JsonObject ?: return@mapNotNull null
            DockerStats(
                id = value.text("id") ?: return@mapNotNull null,
                cpuPercent = value.text("cpu_percent")?.toDoubleOrNull() ?: return@mapNotNull null,
                memoryPercent = value.text("mem_percent")?.toDoubleOrNull() ?: return@mapNotNull null,
                memoryUsage = value.text("mem_usage") ?: return@mapNotNull null,
                networkIo = value.text("net_io") ?: return@mapNotNull null,
                blockIo = value.text("block_io") ?: return@mapNotNull null,
                pids = value.text("pids")?.toLongOrNull() ?: return@mapNotNull null,
            )
        } ?: return CheckedDockerResult.Failure("invalid_docker_stats_response")
        CheckedDockerResult.Stats(items)
    }

    private fun call(nativeCall: (String) -> String): Envelope {
        if (!OrbitCoreBridge.isNativeLibraryAvailable) return Envelope.failure("native_bridge_unavailable")
        val requestId = UUID.randomUUID().toString()
        val raw = runCatching { nativeCall(requestId) }.getOrElse { return Envelope.failure("native_bridge_failed") }
        return runCatching {
            val root = json.parseToJsonElement(raw).jsonObject
            if (root.text("schema_version") != "1" || root.text("request_id") != requestId) {
                return Envelope.failure("uncorrelated_native_response")
            }
            Envelope(root.text("kind") ?: "error", root["data"] as? JsonObject ?: JsonObject(emptyMap()), root["error"] as? JsonObject)
        }.getOrElse { Envelope.failure("invalid_native_response") }
    }

    private data class Envelope(val kind: String, val data: JsonObject, val error: JsonObject?) {
        fun failure() = CheckedDockerResult.Failure(error?.text("code") ?: "native_operation_failed")
        companion object { fun failure(code: String) = Envelope("error", JsonObject(emptyMap()), JsonObject(mapOf("code" to kotlinx.serialization.json.JsonPrimitive(code)))) }
    }
    private companion object { val ACTIONS = setOf("start", "stop", "restart", "kill", "pause", "unpause", "remove") }
}

private fun JsonObject.text(key: String): String? = get(key)?.jsonPrimitive?.content
