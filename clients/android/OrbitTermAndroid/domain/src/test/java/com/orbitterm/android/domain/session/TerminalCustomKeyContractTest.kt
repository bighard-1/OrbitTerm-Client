package com.orbitterm.android.domain.session

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class TerminalCustomKeyContractTest {
    private val actor = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private val other = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private val id = "11111111-1111-1111-1111-111111111111"
    @Serializable private data class Case(val left: List<Int>, val right: List<Int>, val expected: List<Int>, val active: Int)
    @Serializable private data class Vectors(val revisions: List<TerminalCustomKeyRevision>, val cases: List<Case>)
    private fun vectors() = javaClass.getResourceAsStream("/custom-key-merge-vectors.json")!!.bufferedReader().use { Json.decodeFromString<Vectors>(it.readText()) }
    private fun value(payload: String = "a") = TerminalCustomKeyValue("键", payload, "common", 0)
    private fun envelope(vararg rows: TerminalCustomKeyRevision) = TerminalCustomKeyEnvelope.v1(rows.toList())
    private fun blocked(block: () -> Unit) { assertThrows(IllegalArgumentException::class.java, block) }

    @Test fun conflictReviewHasStableOrderWithoutGuessingFromIdenticalValues() {
        val a = TerminalCustomKeyRevision(id, mapOf(actor to 1L), value())
        val b = TerminalCustomKeyRevision(id, mapOf(other to 1L), value())
        val first = TerminalCustomKeyContract.conflicts(envelope(b, a, a))
        assertEquals(first, TerminalCustomKeyContract.conflicts(envelope(a, b)))
        assertEquals(2, first.single().revisions.size)
        assertTrue(TerminalCustomKeyContract.active(envelope(a, b)).isEmpty())
        assertTrue(TerminalCustomKeyContract.conflicts(envelope(a, a)).isEmpty())
    }

    @Test fun reviewedKeepOrDeleteDominatesEveryBranchAndReplay() {
        val a = TerminalCustomKeyRevision(id, mapOf(actor to 1L), value())
        for (otherValue in listOf(value("b"), null)) {
            val b = TerminalCustomKeyRevision(id, mapOf(other to 2L), otherValue)
            val before = envelope(a, b)
            val review = TerminalCustomKeyContract.conflicts(before).single()
            for (keep in listOf(a, null)) {
                val after = TerminalCustomKeyContract.resolving(before, review, keep, actor)
                assertEquals(mapOf(actor to 2L, other to 2L), after.revisions.single().clock)
                assertEquals(keep?.value, after.revisions.single().value)
                assertEquals(after, TerminalCustomKeyContract.merge(after, before))
                assertTrue(TerminalCustomKeyContract.conflicts(after).isEmpty())
            }
        }
    }

    @Test fun stalePartialAndInventedChoicesAreRejected() {
        val a = TerminalCustomKeyRevision(id, mapOf(actor to 1L), value())
        val b = TerminalCustomKeyRevision(id, mapOf(other to 1L), null)
        val before = envelope(a, b)
        val review = TerminalCustomKeyContract.conflicts(before).single()
        val late = TerminalCustomKeyRevision(id, mapOf("cccccccc-cccc-cccc-cccc-cccccccccccc" to 1L), value("c"))
        blocked { TerminalCustomKeyContract.resolving(envelope(a, b, late), review, a, actor) }
        blocked { TerminalCustomKeyContract.resolving(before, review.copy(revisions = listOf(a)), a, actor) }
        for (choice in listOf(late, b)) blocked { TerminalCustomKeyContract.resolving(before, review, choice, actor) }
        val after = TerminalCustomKeyContract.resolving(before, review, a, actor)
        blocked { TerminalCustomKeyContract.resolving(after, review, null, actor) }
    }

    @Test fun sharedMergeVectorsAndWireRoundTrips() {
        val vectors = vectors()
        for (row in vectors.cases) {
            val left = TerminalCustomKeyEnvelope.v1(row.left.map { vectors.revisions[it] })
            val right = TerminalCustomKeyEnvelope.v1(row.right.map { vectors.revisions[it] })
            val result = TerminalCustomKeyContract.merge(left, right)
            assertEquals(row.expected.size, result.revisions.size)
            for (expected in row.expected) assertTrue(result.revisions.contains(vectors.revisions[expected]))
            assertEquals(row.active, TerminalCustomKeyContract.active(result).size)
            assertEquals(result, TerminalCustomKeyContract.merge(right, left))
            assertEquals(result, TerminalCustomKeyContract.merge(result, result))
            assertEquals(result, TerminalCustomKeyContract.decode(TerminalCustomKeyContract.encode(result)))
        }
    }

    @Test fun mergeAssociativityForCausalAndConcurrentHistories() {
        val rows = vectors().revisions
        for (a in listOf(0, 2, 3, 4, 5)) for (b in listOf(0, 2, 3, 4, 5)) for (c in listOf(0, 2, 3, 4, 5)) {
            val x = envelope(rows[a]); val y = envelope(rows[b]); val z = envelope(rows[c])
            assertEquals(TerminalCustomKeyContract.merge(TerminalCustomKeyContract.merge(x, y), z),
                TerminalCustomKeyContract.merge(x, TerminalCustomKeyContract.merge(y, z)))
        }
    }

    @Test fun explicitResolutionDominatesBothBranchesAndStaleReplay() {
        val rows = vectors().revisions
        val conflict = TerminalCustomKeyContract.merge(envelope(rows[3]), envelope(rows[2]))
        val deleted = TerminalCustomKeyContract.replacing(conflict, id, actor, null)
        assertEquals(mapOf(actor to 3L, other to 1L), deleted.revisions.single().clock)
        assertTrue(TerminalCustomKeyContract.active(TerminalCustomKeyContract.merge(deleted, conflict)).isEmpty())
        val restored = TerminalCustomKeyContract.replacing(deleted, id, other, value())
        assertEquals(1, TerminalCustomKeyContract.active(restored).size)
        assertEquals(restored, TerminalCustomKeyContract.merge(restored, deleted))
    }

    @Test fun strictSchemaVersionsAndInvalidInputsAreBlocked() {
        val valid = TerminalCustomKeyContract.encode(envelope(TerminalCustomKeyRevision(id, mapOf(actor to 1L), value())))
        assertEquals(TerminalCustomKeyContract.decode(valid), TerminalCustomKeyContract.decode(valid.replace("\"version\":1", "\"version\":1e0")))
        for (duplicate in listOf(valid.replace("\"version\":1", "\"version\":1,\"version\":1"),
            valid.replace("\"id\":", "\"\\u0069d\":\"$id\",\"id\":"))) blocked { TerminalCustomKeyContract.decode(duplicate) }
        assertFalse(TerminalCustomKeyContract.validId(id + "\n"))
        assertTrue(TerminalCustomKeyContract.validLabel("😀".repeat(16)))
        for (label in listOf("😀".repeat(17), "\uD83D", " ", "a\n", "a\u2028")) assertFalse(TerminalCustomKeyContract.validLabel(label))
        for (field in listOf("version", "payloadSyntaxVersion")) blocked {
            TerminalCustomKeyContract.decode(valid.replace("\"$field\":1", "\"$field\":2"))
        }
        blocked { TerminalCustomKeyContract.decode(valid.dropLast(1) + ",\"future\":true}") }
        val deleted = TerminalCustomKeyContract.encode(envelope(TerminalCustomKeyRevision(id, mapOf(actor to 1L), null)))
        assertTrue(deleted.contains("\"value\":null"))
        blocked { TerminalCustomKeyContract.decode(deleted.replace(",\"value\":null", "")) }
        for (payload in listOf("", "\\x+F", "a".repeat(65))) blocked {
            TerminalCustomKeyContract.validate(envelope(TerminalCustomKeyRevision(id, mapOf(actor to 1L), value(payload))))
        }
        blocked { TerminalCustomKeyContract.decode(" ".repeat(TerminalCustomKeyContract.MAX_BYTES + 1)) }
    }

    @Test fun revisionCollisionUsesExactUnicodeBytes() {
        val left = envelope(TerminalCustomKeyRevision(id, mapOf(actor to 1L), value("é")))
        val right = envelope(TerminalCustomKeyRevision(id, mapOf(actor to 1L), value("e\u0301")))
        blocked { TerminalCustomKeyContract.merge(left, right) }
        blocked { TerminalCustomKeyContract.merge(left, envelope(TerminalCustomKeyRevision(id, mapOf(actor to 1L), null))) }
        val concurrent = TerminalCustomKeyContract.merge(left, envelope(TerminalCustomKeyRevision(id, mapOf(other to 1L), value("e\u0301"))))
        assertEquals(2, concurrent.revisions.size)
        assertTrue(TerminalCustomKeyContract.active(concurrent).isEmpty())
    }

    @Test fun boundsNeverTruncateKeysConflictsOrTombstones() {
        fun identifier(n: Int) = "00000000-0000-0000-0000-" + n.toString().padStart(12, '0')
        val keys = (0..64).map { TerminalCustomKeyRevision(identifier(it), mapOf(actor to 1L), value()) }
        blocked { TerminalCustomKeyContract.merge(TerminalCustomKeyEnvelope.v1(keys.take(64)), envelope(keys[64])) }
        val tombstones = (0..256).map { TerminalCustomKeyRevision(identifier(it), mapOf(actor to 1L), null) }
        blocked { TerminalCustomKeyContract.merge(TerminalCustomKeyEnvelope.v1(tombstones.take(256)), envelope(tombstones[256])) }
        val conflicts = (0..8).map { TerminalCustomKeyRevision(id, mapOf(identifier(it) to 1L), value()) }
        blocked { TerminalCustomKeyContract.merge(TerminalCustomKeyEnvelope.v1(conflicts.take(8)), envelope(conflicts[8])) }
        blocked { TerminalCustomKeyContract.replacing(envelope(TerminalCustomKeyRevision(id, mapOf(actor to TerminalCustomKeyContract.MAX_COUNTER), null)), id, actor, value()) }
        blocked { TerminalCustomKeyContract.validate(envelope(TerminalCustomKeyRevision(id, emptyMap(), null))) }
    }
}
