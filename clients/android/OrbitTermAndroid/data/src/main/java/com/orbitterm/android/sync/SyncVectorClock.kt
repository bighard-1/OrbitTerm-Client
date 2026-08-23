package com.orbitterm.android.sync

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive

/** Canonical vector-clock operations shared by asset and snippet sync. */
object SyncVectorClock {
    private val json = Json { ignoreUnknownKeys = true }

    fun bump(raw: String, actor: String): String {
        require(actor.isNotBlank())
        val values = decode(raw).toMutableMap()
        values[actor] = (values[actor] ?: 0) + 1
        return JsonObject(values.toSortedMap().mapValues { JsonPrimitive(it.value) }).toString()
    }

    fun decode(raw: String): Map<String, Int> = runCatching {
        val objectValue = json.parseToJsonElement(raw) as? JsonObject ?: return emptyMap()
        objectValue.mapNotNull { (actor, value) ->
            value.jsonPrimitive.intOrNull?.takeIf { it >= 0 }?.let { actor to it }
        }.toMap()
    }.getOrDefault(emptyMap())
}
