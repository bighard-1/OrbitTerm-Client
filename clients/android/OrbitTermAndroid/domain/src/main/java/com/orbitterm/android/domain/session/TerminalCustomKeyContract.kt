package com.orbitterm.android.domain.session

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.decodeFromJsonElement

@Serializable
data class TerminalCustomKeyValue(val label: String, val payload: String, val section: String, val order: Int)

@Serializable
data class TerminalCustomKeyRevision(val id: String, val clock: Map<String, Long>, val value: TerminalCustomKeyValue?)

@Serializable
data class TerminalCustomKeyEnvelope(
    val kind: String, val version: Int, val payloadSyntaxVersion: Int, val revisions: List<TerminalCustomKeyRevision>,
) {
    companion object {
        fun v1(revisions: List<TerminalCustomKeyRevision>) = TerminalCustomKeyEnvelope("terminal_custom_keys", 1, 1, revisions)
    }
}

data class TerminalCustomKeyConflict(val id: String, val revisions: List<TerminalCustomKeyRevision>) {
    val explanation: String get() = if (revisions.any { it.value == null })
        "同一按键存在并发修改或删除，无法自动判断应保留哪个版本。"
    else "同一按键存在并发修改，无法自动判断应保留哪个版本。"
}

data class TerminalCustomKeyImportPlan(
    val before: TerminalCustomKeyEnvelope, val incoming: TerminalCustomKeyEnvelope,
    val merged: TerminalCustomKeyEnvelope, val changes: List<Change>, val activeCount: Int, val conflictCount: Int,
) {
    data class Change(val id: String, val before: List<TerminalCustomKeyRevision>, val after: List<TerminalCustomKeyRevision>)
    companion object {
        fun make(current: TerminalCustomKeyEnvelope, incoming: TerminalCustomKeyEnvelope): TerminalCustomKeyImportPlan {
            val before = TerminalCustomKeyContract.merge(current, TerminalCustomKeyEnvelope.v1(emptyList()))
            val merged = TerminalCustomKeyContract.merge(before, incoming)
            val old = before.revisions.groupBy { it.id }; val next = merged.revisions.groupBy { it.id }
            val changes = (old.keys + next.keys).sorted().mapNotNull { id ->
                val a = old[id].orEmpty(); val b = next[id].orEmpty()
                if (a == b) null else Change(id, a, b)
            }
            return TerminalCustomKeyImportPlan(before, incoming, merged, changes,
                TerminalCustomKeyContract.active(merged).size, TerminalCustomKeyContract.conflicts(merged).size)
        }
    }
}

/** Pure model only. No network writes or decrypted persistent storage. */
object TerminalCustomKeyContract {
    enum class Reason { INVALID, UNSUPPORTED, CAPACITY, REVISION_COLLISION }
    class Failure(val reason: Reason) : IllegalArgumentException("Custom key contract: $reason")
    const val MAX_COUNTER = 9_007_199_254_740_991L
    const val MAX_BYTES = 262_144
    private val uuid = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    fun validId(value: String) = uuid.matches(value)
    fun validLabel(label: String): Boolean {
        val scalars = label.codePoints().toArray()
        return scalars.size in 1..16 && scalars.any { it != 32 } &&
            scalars.none { it < 32 || it in 127..159 || it == 0x2028 || it == 0x2029 || it in 0xD800..0xDFFF }
    }

    fun decode(plaintext: String): TerminalCustomKeyEnvelope {
        // Strict defaults reject unknown fields and missing required fields.
        val result = try {
            val tree = parseUnambiguousJson(plaintext)
            Json.decodeFromJsonElement<TerminalCustomKeyEnvelope>(normalizeNumbers(tree))
        }
        catch (_: kotlinx.serialization.SerializationException) { throw Failure(Reason.INVALID) }
        validate(result)
        return result
    }

    /** Shared read boundary for v1 and legacy migration: never pick a winner for
     * duplicate JSON fields. The returned tree still requires schema validation. */
    fun parseUnambiguousJson(plaintext: String, maximumBytes: Int = MAX_BYTES): JsonElement {
        check(plaintext.toByteArray(Charsets.UTF_8).size <= maximumBytes, Reason.CAPACITY)
        val tree = Json.parseToJsonElement(plaintext)
        check(hasUniqueObjectKeys(plaintext), Reason.INVALID)
        return tree
    }

    fun encode(envelope: TerminalCustomKeyEnvelope): String {
        validate(envelope)
        val result = Json.encodeToString(envelope)
        check(result.toByteArray(Charsets.UTF_8).size <= MAX_BYTES, Reason.CAPACITY)
        return result
    }

    fun validate(envelope: TerminalCustomKeyEnvelope) {
        check(envelope.kind == "terminal_custom_keys" && envelope.version == 1 && envelope.payloadSyntaxVersion == 1, Reason.UNSUPPORTED)
        check(envelope.revisions.size <= 256, Reason.CAPACITY)
        val grouped = envelope.revisions.groupBy { it.id }
        check(grouped.values.all { it.size <= 8 } && envelope.revisions.filter { it.value != null }.map { it.id }.toSet().size <= 64, Reason.CAPACITY)
        for (row in envelope.revisions) {
            check(validId(row.id) && row.clock.isNotEmpty() && row.clock.size <= 32 &&
                row.clock.all { validId(it.key) && it.value in 1..MAX_COUNTER }, Reason.INVALID)
            row.value?.let { value ->
                check(validLabel(value.label) &&
                    value.section in listOf("common", "symbols") && value.order in 0..1_000_000 &&
                    TerminalCustomKeyPayload.decode(value.payload) != null, Reason.INVALID)
            }
        }
        for (rows in grouped.values) for (a in rows) {
            check(rows.none { it.clock == a.clock && it.value != a.value }, Reason.REVISION_COLLISION)
        }
    }

    fun merge(left: TerminalCustomKeyEnvelope, right: TerminalCustomKeyEnvelope): TerminalCustomKeyEnvelope {
        validate(left)
        validate(right)
        val result = (left.revisions + right.revisions).groupBy { it.id }.values.flatMap { rows ->
            val unique = rows.distinct()
            for (a in unique) check(unique.none { it.clock == a.clock && it.value != a.value }, Reason.REVISION_COLLISION)
            unique.filter { row -> unique.none { dominates(it.clock, row.clock) } }
        }.sortedWith(compareBy({ it.id }, { clockKey(it.clock) }))
        return TerminalCustomKeyEnvelope.v1(result).also { encode(it) } // Bound violations block, never truncate.
    }

    /** Edit/delete/resolve only after the caller has observed every revision for this key. */
    fun replacing(envelope: TerminalCustomKeyEnvelope, id: String, actor: String, value: TerminalCustomKeyValue?): TerminalCustomKeyEnvelope {
        validate(envelope)
        check(validId(id) && validId(actor), Reason.INVALID)
        val clock = mutableMapOf<String, Long>()
        for (row in envelope.revisions.filter { it.id == id }) for ((source, count) in row.clock) {
            clock[source] = maxOf(clock[source] ?: 0, count)
        }
        check((clock[actor] ?: 0) < MAX_COUNTER, Reason.CAPACITY)
        clock[actor] = (clock[actor] ?: 0) + 1
        return merge(TerminalCustomKeyEnvelope.v1(envelope.revisions.filterNot { it.id == id } +
            TerminalCustomKeyRevision(id, clock, value)), TerminalCustomKeyEnvelope.v1(emptyList()))
    }

    fun active(envelope: TerminalCustomKeyEnvelope): List<TerminalCustomKeyRevision> =
        merge(envelope, TerminalCustomKeyEnvelope.v1(emptyList())).revisions.groupBy { it.id }.values
            .mapNotNull { rows -> rows.singleOrNull()?.takeIf { it.value != null } }
            .sortedWith(compareBy({ it.value!!.section }, { it.value!!.order }, { it.id }))

    fun conflicts(envelope: TerminalCustomKeyEnvelope): List<TerminalCustomKeyConflict> =
        merge(envelope, TerminalCustomKeyEnvelope.v1(emptyList())).revisions.groupBy { it.id }
            .filterValues { it.size > 1 }.map { TerminalCustomKeyConflict(it.key, it.value) }.sortedBy { it.id }

    /** A decision observes every branch, and is invalid if any branch changed. */
    fun resolving(envelope: TerminalCustomKeyEnvelope, observed: TerminalCustomKeyConflict,
        keeping: TerminalCustomKeyRevision?, actor: String): TerminalCustomKeyEnvelope {
        check(conflicts(envelope).contains(observed) &&
            (keeping == null || (keeping.value != null && keeping in observed.revisions)), Reason.INVALID)
        return replacing(envelope, observed.id, actor, keeping?.value)
    }

    private fun dominates(a: Map<String, Long>, b: Map<String, Long>): Boolean {
        val keys = a.keys + b.keys
        return keys.all { (a[it] ?: 0) >= (b[it] ?: 0) } && keys.any { (a[it] ?: 0) > (b[it] ?: 0) }
    }
    private fun clockKey(clock: Map<String, Long>) = clock.toSortedMap().entries.joinToString(";") { "${it.key}:${it.value}" }
    // JSONDecoder accepts integer-valued JSON numbers such as 1.0/1e0. Match that
    // behavior exactly, without Double rounding or coercing numeric strings.
    private fun normalizeNumbers(element: JsonElement): JsonElement {
        fun integer(value: JsonElement): JsonElement {
            val primitive = value as? JsonPrimitive ?: return value
            if (primitive.isString) return value
            return runCatching { JsonPrimitive(primitive.content.toBigDecimal().longValueExact()) }.getOrDefault(value)
        }
        val root = element as? JsonObject ?: return element
        return JsonObject(root.mapValues { (key, value) -> when (key) {
            "version", "payloadSyntaxVersion" -> integer(value)
            "revisions" -> (value as? JsonArray)?.let { rows -> JsonArray(rows.map { row ->
                (row as? JsonObject)?.let { objectValue -> JsonObject(objectValue.mapValues { (field, content) -> when (field) {
                    "clock" -> (content as? JsonObject)?.let { JsonObject(it.mapValues { (_, number) -> integer(number) }) } ?: content
                    "value" -> (content as? JsonObject)?.let { JsonObject(it.mapValues { (name, number) -> if (name == "order") integer(number) else number }) } ?: content
                    else -> content
                } }) } ?: row
            }) } ?: value
            else -> value
        } })
    }
    private fun check(condition: Boolean, reason: Reason) { if (!condition) throw Failure(reason) }

    // Called after syntax validation. Reject repeated keys, including escaped
    // aliases, instead of relying on platform-specific first/last-key behavior.
    private fun hasUniqueObjectKeys(text: String): Boolean {
        val scopes = mutableListOf<MutableSet<String>?>()
        var index = 0
        while (index < text.length) {
            when (text[index]) {
                '{' -> scopes.add(mutableSetOf())
                '[' -> scopes.add(null)
                '}', ']' -> scopes.removeAt(scopes.lastIndex)
                '"' -> {
                    val start = index++
                    while (index < text.length && text[index] != '"') {
                        if (text[index] == '\\') index++
                        index++
                    }
                    var next = index + 1
                    while (next < text.length && text[next] in "\t\n\r ") next++
                    if (next < text.length && text[next] == ':') {
                        val key = Json.decodeFromString<String>(text.substring(start, index + 1))
                        val keys = scopes.lastOrNull() ?: return false
                        if (!keys.add(key)) return false
                    }
                }
            }
            index++
        }
        return true
    }
}
