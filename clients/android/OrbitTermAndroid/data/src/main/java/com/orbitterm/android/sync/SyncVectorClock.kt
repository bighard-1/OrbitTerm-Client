package com.orbitterm.android.sync

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/** Canonical vector-clock operations shared by asset and snippet sync. */
object SyncVectorClock {
    private val json = Json { ignoreUnknownKeys = true }

    fun bump(raw: String, actor: String): String {
        require(actor.isNotBlank())
        val values = decode(raw).toMutableMap()
        values[actor] = (values[actor] ?: 0L) + 1L
        return JsonObject(values.toSortedMap().mapValues { JsonPrimitive(it.value) }).toString()
    }

    fun decode(raw: String): Map<String, Long> = runCatching {
        val objectValue = json.parseToJsonElement(raw) as? JsonObject ?: return emptyMap()
        objectValue.mapNotNull { (actor, value) ->
            value.jsonPrimitive.longOrNull?.takeIf { it >= 0L }?.let { actor to it }
        }.toMap()
    }.getOrDefault(emptyMap())
}
