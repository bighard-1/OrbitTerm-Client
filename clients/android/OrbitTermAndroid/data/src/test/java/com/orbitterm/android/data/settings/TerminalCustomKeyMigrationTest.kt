package com.orbitterm.android.data.settings

import com.orbitterm.android.domain.session.TerminalCustomKey
import com.orbitterm.android.domain.session.TerminalCustomKeySection
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class TerminalCustomKeyMigrationTest {
    private val actor = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private val id = "11111111-1111-1111-1111-111111111111"
    private fun row(identity: String = id, label: String = "键", payload: String = "😀\\x1B", section: String = "Common") = buildJsonObject {
        put("id", identity); put("label", label); put("payload", payload); put("section", section)
    }
    private val newKey = TerminalCustomKey("22222222-2222-2222-2222-222222222222", "新键", "a", TerminalCustomKeySection.Symbols)

    @Test fun migrationPreservesIdentityBytesSectionsAndOrderWithoutWriting() {
        val original = JsonArray(listOf(row(), row(newKey.id, section = "Symbols"))).toString()
        val result = TerminalCustomKeyMigrationPlan.inspect(original, actor) as TerminalCustomKeyMigrationPlan.Result.Ready
        assertEquals(listOf(id, newKey.id), result.envelope.revisions.map { it.id })
        assertEquals(listOf("common", "symbols"), result.envelope.revisions.map { it.value!!.section })
        assertEquals(listOf(0, 1), result.envelope.revisions.map { it.value!!.order })
        assertEquals("😀\\x1B", result.envelope.revisions[0].value!!.payload)
        assertEquals(result, TerminalCustomKeyMigrationPlan.inspect(original, actor))
    }

    @Test fun malformedUnknownAndLegacyInvalidRowsBlockWholeMigration() {
        val invalid = listOf("", "null", "{", "{}", JsonArray(listOf(row(payload = "\\x+F"))).toString(),
            JsonArray(listOf(row(label = "x".repeat(17)))).toString(),
            JsonArray(listOf(row(section = "Future"))).toString(),
            JsonArray(listOf(row(identity = "old-not-uuid"))).toString(),
            JsonArray(listOf(JsonObject(row() + ("future" to JsonPrimitive(true))))).toString())
        for (source in invalid) assertTrue(TerminalCustomKeyMigrationPlan.inspect(source, actor) is TerminalCustomKeyMigrationPlan.Result.Blocked)
        assertTrue(TerminalCustomKeyMigrationPlan.inspect(null, actor) is TerminalCustomKeyMigrationPlan.Result.Ready)
        assertTrue(TerminalCustomKeyMigrationPlan.inspect("[]", "") is TerminalCustomKeyMigrationPlan.Result.Blocked)
    }

    @Test fun duplicatesAndCapacityNeverProducePartialMigration() {
        assertEquals(TerminalCustomKeyMigrationPlan.Result.Blocked(TerminalCustomKeyMigrationPlan.Reason.DUPLICATE_ID),
            TerminalCustomKeyMigrationPlan.inspect(JsonArray(listOf(row(), row())).toString(), actor))
        val rows = (0..64).map { row(identity = "00000000-0000-0000-0000-" + it.toString().padStart(12, '0')) }
        assertTrue(TerminalCustomKeyMigrationPlan.inspect(JsonArray(rows).toString(), actor) is TerminalCustomKeyMigrationPlan.Result.Blocked)
    }

    @Test fun unrelatedEditsPreserveHiddenAndInvalidLegacyRows() {
        for (legacy in listOf(row(payload = "\\x+F"), row(label = ""), row(payload = ""), row(section = "Future"))) {
            val original = JsonArray(listOf(legacy)).toString()
            val saved = TerminalCustomKeyLegacyCodec.saving(original, newKey)
            assertEquals(legacy, Json.parseToJsonElement(saved).jsonArray[0])
            val removed = TerminalCustomKeyLegacyCodec.deleting(saved, newKey.id)
            assertEquals(Json.parseToJsonElement(original), Json.parseToJsonElement(removed))
        }
    }

    @Test fun corruptUnknownOrDuplicateStorageCannotBeOverwrittenBySaveOrDelete() {
        for (source in listOf("{", "null", JsonArray(listOf(row(), row())).toString(),
            JsonArray(listOf(row())).toString().replace("\"id\":", "\"id\":\"$id\",\"id\":"),
            JsonArray(listOf(JsonObject(row() + ("future" to JsonPrimitive(true))))).toString())) {
            assertThrows(IllegalStateException::class.java) { TerminalCustomKeyLegacyCodec.saving(source, newKey) }
            assertThrows(IllegalStateException::class.java) { TerminalCustomKeyLegacyCodec.deleting(source, newKey.id) }
            assertTrue(TerminalCustomKeyMigrationPlan.inspect(source, actor) is TerminalCustomKeyMigrationPlan.Result.Blocked)
        }
    }
}
