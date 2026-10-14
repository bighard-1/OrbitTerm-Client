package com.orbitterm.android.data.settings

import com.orbitterm.android.domain.session.TerminalCustomKeyContract
import com.orbitterm.android.domain.session.TerminalCustomKeyEnvelope
import com.orbitterm.android.domain.session.TerminalCustomKeyRevision
import com.orbitterm.android.domain.session.TerminalCustomKeyValue
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Pure preflight only. The repository retains the original as an encrypted
 * backup and commits the verified ciphertext/source removal in one transaction. */
object TerminalCustomKeyMigrationPlan {
    sealed interface Result {
        data class Ready(val envelope: TerminalCustomKeyEnvelope) : Result
        data class Blocked(val reason: Reason) : Result
    }
    enum class Reason { INVALID_SOURCE, DUPLICATE_ID, CONTRACT_REJECTED }

    fun inspect(encoded: String?, actor: String): Result {
        if (!TerminalCustomKeyContract.validId(actor)) return Result.Blocked(Reason.CONTRACT_REJECTED)
        if (encoded == null) return Result.Ready(TerminalCustomKeyEnvelope.v1(emptyList()))
        if (encoded.toByteArray(Charsets.UTF_8).size > TerminalCustomKeyContract.MAX_BYTES)
            return Result.Blocked(Reason.CONTRACT_REJECTED)
        val rows = runCatching { TerminalCustomKeyContract.parseUnambiguousJson(encoded) as? JsonArray }.getOrNull()
            ?: return Result.Blocked(Reason.INVALID_SOURCE)
        val seen = mutableSetOf<String>()
        val revisions = mutableListOf<TerminalCustomKeyRevision>()
        for ((index, element) in rows.withIndex()) {
            val row = element as? JsonObject ?: return Result.Blocked(Reason.INVALID_SOURCE)
            if (row.keys != setOf("id", "label", "payload", "section")) return Result.Blocked(Reason.INVALID_SOURCE)
            fun string(name: String) = (row[name] as? JsonPrimitive)?.takeIf { it.isString }?.content
            val id = string("id") ?: return Result.Blocked(Reason.INVALID_SOURCE)
            val label = string("label") ?: return Result.Blocked(Reason.INVALID_SOURCE)
            val payload = string("payload") ?: return Result.Blocked(Reason.INVALID_SOURCE)
            val section = when (string("section")) {
                "Common" -> "common"
                "Symbols" -> "symbols"
                else -> return Result.Blocked(Reason.INVALID_SOURCE)
            }
            if (!seen.add(id)) return Result.Blocked(Reason.DUPLICATE_ID)
            revisions += TerminalCustomKeyRevision(id, mapOf(actor to 1L), TerminalCustomKeyValue(label, payload, section, index))
        }
        val envelope = TerminalCustomKeyEnvelope.v1(revisions)
        return try {
            TerminalCustomKeyContract.encode(envelope)
            Result.Ready(envelope)
        } catch (_: TerminalCustomKeyContract.Failure) {
            Result.Blocked(Reason.CONTRACT_REJECTED)
        }
    }
}
