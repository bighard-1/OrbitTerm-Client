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

    /** Never use the permissive decoder as proof that a remote tombstone covers a request. */
    fun strictlyCovers(request: String?, observed: String?): Boolean {
        val requested = request?.let(::strictDecode)?.takeIf { it.isNotEmpty() } ?: return false
        val remote = observed?.let(::strictDecode) ?: return false
        return requested.all { (actor, value) -> (remote[actor] ?: return@all false) >= value }
    }

    fun isValid(raw: String): Boolean = strictDecode(raw) != null

    private fun strictDecode(raw: String): Map<String, Long>? = runCatching {
        val value = json.parseToJsonElement(raw) as? JsonObject ?: return null
        value.map { (actor, element) ->
            if (actor.isBlank()) return null
            val primitive = element.jsonPrimitive
            if (primitive.isString) return null
            val number = primitive.longOrNull?.takeIf { it >= 0L } ?: return null
            actor to number
        }.toMap()
    }.getOrNull()
}
