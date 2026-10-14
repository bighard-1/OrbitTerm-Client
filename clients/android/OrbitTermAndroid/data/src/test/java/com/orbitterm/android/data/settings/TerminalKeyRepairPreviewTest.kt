package com.orbitterm.android.data.settings

import com.orbitterm.android.domain.session.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class TerminalKeyRepairPreviewTest {
    private fun row(id: String = "11111111-1111-1111-1111-111111111111",
        label: String = "键", payload: String = "hidden-command", section: String = "Common") = buildJsonObject {
        put("id", id); put("label", label); put("payload", payload); put("section", section)
    }

    @Test fun enumeratesEveryRowWithoutExposingPayloadOrInventingRepairs() {
        val input = JsonArray(listOf(
            row(payload = "private-command\\r"),
            row(id = "22222222-2222-2222-2222-222222222222", label = "bad\u202Ename", section = "Future"),
            JsonPrimitive("not-an-object"),
        )).toString()
        val preview = TerminalKeyRepairPreviewParser.androidLegacy(input, protectedSourcePresent = true)
        assertNull(preview.blockedReason)
        assertTrue(preview.protectedSourcePresent)
        assertEquals(3, preview.items.size)
        assertEquals(TerminalKeyRepairDisposition.KeepUnchanged, preview.items[0].disposition)
        assertEquals("…11111111", preview.items[0].idSummary)
        assertEquals("private-command\\r".toByteArray(Charsets.UTF_8).size, preview.items[0].payloadUtf8Bytes)
        assertFalse(preview.toString().contains("private-command"))
        assertEquals(TerminalKeyRepairDisposition.ManualCorrectionRequired, preview.items[1].disposition)
        assertTrue(preview.items[1].issues.contains(TerminalKeyRepairIssue.InvalidSection))
        assertEquals("bad\\u{202E}name", preview.items[1].labelSummary)
        assertEquals(TerminalKeyRepairDisposition.CannotInterpret, preview.items[2].disposition)
    }

    @Test fun malformedAmbiguousWrongRootAndOversizedCollectionsBlockWholePreview() {
        for (source in listOf("{", "null", "{}",
            "[{\"id\":\"a\",\"id\":\"b\"}]")) {
            assertNotNull(TerminalKeyRepairPreviewParser.androidLegacy(source, false).blockedReason)
        }
        val rows = JsonArray((0..256).map { row(id = "00000000-0000-0000-0000-${it.toString().padStart(12, '0')}") })
        val oversized = TerminalKeyRepairPreviewParser.androidLegacy(rows.toString(), false)
        assertEquals(TerminalKeyRepairBlockedReason.TooManyItems, oversized.blockedReason)
        assertTrue(oversized.items.isEmpty())
    }

    @Test fun capacityNeverSilentlyChoosesRowsAndSummariesAreBounded() {
        val rows = JsonArray((0..64).map { index ->
            row(id = "00000000-0000-0000-0000-${index.toString().padStart(12, '0')}", label = "x".repeat(30) + "\\")
        })
        val preview = TerminalKeyRepairPreviewParser.androidLegacy(rows.toString(), false)
        assertEquals(65, preview.items.size)
        assertTrue(preview.items.all { TerminalKeyRepairIssue.CapacitySelectionRequired in it.issues })
        assertTrue(preview.items.all { it.disposition == TerminalKeyRepairDisposition.ManualCorrectionRequired })
        assertTrue(preview.items.all { it.labelSummary!!.length <= 26 })
        assertTrue(preview.items.first().labelSummary!!.endsWith("…"))
    }

    @Test fun decisionPlanRequiresEveryChoiceAndDoesNotRetainReplacementPayload() {
        val input = JsonArray(listOf(row(), row(id = "22222222-2222-2222-2222-222222222222",
            label = "bad\u202Ename", section = "Future"))).toString()
        val preview = TerminalKeyRepairPreviewParser.androidLegacy(input, false)
        val incomplete = TerminalKeyRepairDecisionPlanner.make(preview, "session-a",
            mapOf(0 to TerminalKeyRepairDecision(TerminalKeyRepairChoice.Keep)))
        assertFalse(incomplete.isReadyForSecondConfirmation)
        assertTrue(incomplete.issues.contains(TerminalKeyRepairDecisionIssue.MissingDecision(1)))
        val correction = TerminalKeyRepairCorrection("修正键", "replacement-command\\r", "symbols")
        val decisions = mapOf(0 to TerminalKeyRepairDecision(TerminalKeyRepairChoice.Keep),
            1 to TerminalKeyRepairDecision(TerminalKeyRepairChoice.Correct, correction))
        val complete = TerminalKeyRepairDecisionPlanner.make(preview, "session-a", decisions)
        assertTrue(complete.isReadyForSecondConfirmation)
        assertEquals(1, complete.keptCount); assertEquals(1, complete.correctedCount)
        assertEquals(2, complete.activeIdentityCount)
        assertEquals(correction.payload.toByteArray().size, complete.rows[1].payloadUtf8Bytes)
        assertFalse(complete.toString().contains("replacement-command"))
        assertEquals(16, complete.confirmationBaseline!!.length)
        assertNotEquals(complete.confirmationBaseline,
            TerminalKeyRepairDecisionPlanner.make(preview, "session-b", decisions).confirmationBaseline)
    }

    @Test fun decisionsRejectUnsafeKeepInvalidCorrectionAndProtectedConflict() {
        val preview = TerminalKeyRepairPreviewParser.androidLegacy(JsonArray(listOf(
            row(id = "bad-id", section = "Future"), JsonPrimitive("not-an-object"))).toString(), false)
        val invalid = TerminalKeyRepairDecisionPlanner.make(preview, "session", mapOf(
            0 to TerminalKeyRepairDecision(TerminalKeyRepairChoice.Keep),
            1 to TerminalKeyRepairDecision(TerminalKeyRepairChoice.Correct,
                TerminalKeyRepairCorrection("键", "\\r", "common"))))
        assertTrue(invalid.issues.contains(TerminalKeyRepairDecisionIssue.InvalidChoice(0)))
        assertTrue(invalid.issues.contains(TerminalKeyRepairDecisionIssue.InvalidCorrection(1)))
        assertNull(invalid.confirmationBaseline)
        val safe = TerminalKeyRepairPreviewParser.androidLegacy(JsonArray(listOf(row())).toString(), true)
        val blocked = TerminalKeyRepairDecisionPlanner.make(safe, "session",
            mapOf(0 to TerminalKeyRepairDecision(TerminalKeyRepairChoice.Exclude)))
        assertTrue(blocked.issues.contains(TerminalKeyRepairDecisionIssue.ProtectedSourceConflict))
        assertTrue(blocked.requiresDataLossAcknowledgement)
        assertFalse(blocked.isReadyForSecondConfirmation)
    }

    @Test fun capacityMustBeReducedByAnExplicitChoice() {
        val rows = JsonArray((0..64).map { index ->
            row(id = "00000000-0000-0000-0000-${index.toString().padStart(12, '0')}")
        })
        val preview = TerminalKeyRepairPreviewParser.androidLegacy(rows.toString(), false)
        val decisions = preview.items.associate { it.index to TerminalKeyRepairDecision(TerminalKeyRepairChoice.Keep) }.toMutableMap()
        assertTrue(TerminalKeyRepairDecisionPlanner.make(preview, "session", decisions).issues
            .contains(TerminalKeyRepairDecisionIssue.CapacityExceeded(65)))
        decisions[64] = TerminalKeyRepairDecision(TerminalKeyRepairChoice.CapacityExclude)
        val reduced = TerminalKeyRepairDecisionPlanner.make(preview, "session", decisions)
        assertTrue(reduced.isReadyForSecondConfirmation)
        assertEquals(64, reduced.activeIdentityCount)
        assertEquals(1, reduced.excludedCount)
        assertTrue(reduced.requiresDataLossAcknowledgement)
    }
}
