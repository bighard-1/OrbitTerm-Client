package com.orbitterm.android.core

import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

data class MonitorSnapshot(
    val sampledAtUnix: Long,
    val cpuUsagePercent: Double,
    val memoryUsedPercent: Double,
    val diskUsedPercent: Double,
    val memoryAvailableMb: Long,
    val rxRateKbps: Double,
    val txRateKbps: Double,
    val pingLatencyMs: Double?,
    val osName: String,
    val cpuCoreCount: Long,
    val memoryTotalMb: Long,
    val diskTotalMb: Long,
)

sealed interface CheckedMonitorResult {
    data class Snapshot(val snapshot: MonitorSnapshot) : CheckedMonitorResult
    data class Failure(val code: String) : CheckedMonitorResult
}

/** Reads one bounded monitor snapshot through the checked, verified-session ABI. */
@Singleton
class CheckedMonitorNativeClient @Inject constructor() {
    private val json = Json { ignoreUnknownKeys = true }

    fun snapshot(baseSessionId: Long): CheckedMonitorResult {
        if (!OrbitCoreBridge.isNativeLibraryAvailable || baseSessionId <= 0) {
            return CheckedMonitorResult.Failure("native_bridge_unavailable")
        }
        val requestId = UUID.randomUUID().toString()
        val raw = runCatching {
            OrbitCoreBridge.orbitMonitorSnapshot(baseSessionId, requestId)
        }.getOrElse { return CheckedMonitorResult.Failure("native_bridge_failed") }
        val root = runCatching { json.parseToJsonElement(raw).jsonObject }
            .getOrElse { return CheckedMonitorResult.Failure("invalid_native_response") }
        if (root.value("schema_version") != "1" || root.value("request_id") != requestId) {
            return CheckedMonitorResult.Failure("uncorrelated_native_response")
        }
        if (root.value("kind") != "monitor_snapshot") {
            return CheckedMonitorResult.Failure(root["error"]?.jsonObject?.value("code") ?: "native_operation_failed")
        }
        val stats = root["data"]?.jsonObject?.get("stats")?.jsonObject
            ?: return CheckedMonitorResult.Failure("invalid_monitor_snapshot")
        val system = stats["system_info"]?.jsonObject
            ?: return CheckedMonitorResult.Failure("invalid_monitor_snapshot")
        return MonitorSnapshot(
            sampledAtUnix = stats.long("sampled_at_unix") ?: return CheckedMonitorResult.Failure("invalid_monitor_snapshot"),
            cpuUsagePercent = stats.number("cpu_usage_percent") ?: return CheckedMonitorResult.Failure("invalid_monitor_snapshot"),
            memoryUsedPercent = stats.number("mem_used_percent") ?: return CheckedMonitorResult.Failure("invalid_monitor_snapshot"),
            diskUsedPercent = stats.number("disk_used_percent") ?: return CheckedMonitorResult.Failure("invalid_monitor_snapshot"),
            memoryAvailableMb = stats.long("mem_available_mb") ?: return CheckedMonitorResult.Failure("invalid_monitor_snapshot"),
            rxRateKbps = stats.number("rx_rate_kbps") ?: return CheckedMonitorResult.Failure("invalid_monitor_snapshot"),
            txRateKbps = stats.number("tx_rate_kbps") ?: return CheckedMonitorResult.Failure("invalid_monitor_snapshot"),
            pingLatencyMs = stats.number("ping_latency_ms"),
            osName = system.value("os_name") ?: return CheckedMonitorResult.Failure("invalid_monitor_snapshot"),
            cpuCoreCount = system.long("cpu_core_count") ?: return CheckedMonitorResult.Failure("invalid_monitor_snapshot"),
            memoryTotalMb = system.long("memory_total_mb") ?: return CheckedMonitorResult.Failure("invalid_monitor_snapshot"),
            diskTotalMb = system.long("disk_total_mb") ?: return CheckedMonitorResult.Failure("invalid_monitor_snapshot"),
        ).let(CheckedMonitorResult::Snapshot)
    }
}

private fun JsonObject.value(key: String): String? = get(key)?.jsonPrimitive?.content
private fun JsonObject.long(key: String): Long? = value(key)?.toLongOrNull()
private fun JsonObject.number(key: String): Double? = value(key)?.toDoubleOrNull()
