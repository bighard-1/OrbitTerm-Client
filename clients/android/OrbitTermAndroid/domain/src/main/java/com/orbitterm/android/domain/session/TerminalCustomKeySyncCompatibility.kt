package com.orbitterm.android.domain.session

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Read-only reservation. Never validates, executes, merges, or publishes entries. */
object TerminalCustomKeySyncCompatibility {
    enum class Routing { UNRELATED, DEFERRED, INVALID_ASSET_IDENTITY }

    fun routing(plaintext: String, assetId: String?): Routing {
        val objectValue = runCatching { Json.parseToJsonElement(plaintext) as? JsonObject }.getOrNull()
        val kind = objectValue?.get("kind") as? JsonPrimitive
        if (kind?.isString != true || kind.content != "terminal_custom_keys") return Routing.UNRELATED
        // Deliberately independent of version/entries, including unsupported schemas.
        return if (assetId == null) Routing.DEFERRED else Routing.INVALID_ASSET_IDENTITY
    }
}
