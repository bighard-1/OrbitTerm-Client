package com.orbitterm.android.data.settings

import com.orbitterm.android.domain.session.*
import kotlinx.serialization.json.*
import java.security.MessageDigest

/** Pure, bounded diagnosis. It never creates a replacement document and its
 * summaries escape controls/format characters instead of rendering raw input. */
object TerminalKeyRepairPreviewParser {
    private const val MAX_ITEMS = 256
    private val expected = setOf("id", "label", "payload", "section")

    fun androidLegacy(encoded: String, protectedSourcePresent: Boolean): TerminalKeyRepairPreview {
        val root = try {
            TerminalCustomKeyContract.parseUnambiguousJson(encoded, TerminalKeyRecoveryPackage.MAX_RESCUE_PLAINTEXT)
        } catch (_: Exception) {
            return blocked(TerminalKeyRepairBlockedReason.MalformedOrAmbiguous, protectedSourcePresent)
        }
        val rows = root as? JsonArray
            ?: return blocked(TerminalKeyRepairBlockedReason.RootNotEnumerable, protectedSourcePresent)
        if (rows.size > MAX_ITEMS) return blocked(TerminalKeyRepairBlockedReason.TooManyItems, protectedSourcePresent)
        val stringIds = rows.mapNotNull { row -> (row as? JsonObject)?.get("id")?.let(::string) }
        val identityGroups = linkedMapOf<String, Int>()
        stringIds.filter(TerminalCustomKeyContract::validId).forEach { identityGroups.putIfAbsent(it, identityGroups.size) }
        val duplicates = stringIds.groupingBy { it }.eachCount().filterValues { it > 1 }.keys
        val capacity = stringIds.toSet().size > 64 || rows.size > 64
        val items = rows.mapIndexed { index, element ->
            val row = element as? JsonObject
            if (row == null) return@mapIndexed item(index, null, null, null, null,
                listOf(TerminalKeyRepairIssue.RowNotObject), TerminalKeyRepairDisposition.CannotInterpret, null, false)
            val id = row["id"]?.let(::string)
            val label = row["label"]?.let(::string)
            val payload = row["payload"]?.let(::string)
            val section = row["section"]?.let(::string)
            val issues = mutableListOf<TerminalKeyRepairIssue>()
            if (row.keys != expected) issues += TerminalKeyRepairIssue.UnknownFields
            if (id == null) issues += TerminalKeyRepairIssue.MissingOrWrongId
            else {
                if (!TerminalCustomKeyContract.validId(id)) issues += TerminalKeyRepairIssue.InvalidId
                if (id in duplicates) issues += TerminalKeyRepairIssue.DuplicateId
            }
            if (label == null) issues += TerminalKeyRepairIssue.MissingOrWrongLabel
            else if (!TerminalCustomKeyContract.validLabel(label)) issues += TerminalKeyRepairIssue.InvalidLabel
            if (payload == null) issues += TerminalKeyRepairIssue.MissingOrWrongPayload
            else if (TerminalCustomKeyPayload.decode(payload) == null) issues += TerminalKeyRepairIssue.InvalidPayload
            if (section == null) issues += TerminalKeyRepairIssue.MissingOrWrongSection
            else if (section !in setOf("Common", "Symbols")) issues += TerminalKeyRepairIssue.InvalidSection
            if (capacity) issues += TerminalKeyRepairIssue.CapacitySelectionRequired
            val nonCapacity = issues.any { it != TerminalKeyRepairIssue.CapacitySelectionRequired }
            val disposition = when {
                nonCapacity -> TerminalKeyRepairDisposition.ManualCorrectionRequired
                capacity -> TerminalKeyRepairDisposition.CapacitySelectionRequired
                else -> TerminalKeyRepairDisposition.KeepUnchanged
            }
            item(index, id, label, section, payload?.let(::strictUtf8Size), issues, disposition,
                id?.let(identityGroups::get), true)
        }
        return TerminalKeyRepairPreview(TerminalKeyRepairSource.AndroidLegacy, items = items,
            protectedSourcePresent = protectedSourcePresent)
    }

    private fun blocked(reason: TerminalKeyRepairBlockedReason, protected: Boolean) =
        TerminalKeyRepairPreview(TerminalKeyRepairSource.AndroidLegacy, blockedReason = reason,
            protectedSourcePresent = protected)

    private fun string(element: JsonElement): String? =
        (element as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun strictUtf8Size(value: String): Int? = runCatching {
        Charsets.UTF_8.newEncoder().encode(java.nio.CharBuffer.wrap(value)).remaining()
    }.getOrNull()

    private fun item(index: Int, id: String?, label: String?, section: String?, payloadBytes: Int?,
        issues: List<TerminalKeyRepairIssue>, disposition: TerminalKeyRepairDisposition,
        identityGroup: Int?, isActive: Boolean) = TerminalKeyRepairItem(
        index, id?.let { if (TerminalCustomKeyContract.validId(it)) "…${it.takeLast(8)}" else safe(it) },
        label?.let(::safe), section?.let(::safe), payloadBytes, issues.distinct(), disposition, identityGroup, isActive)

    internal fun safe(value: String, limit: Int = 24): String {
        val result = StringBuilder(); var offset = 0; var count = 0
        while (offset < value.length && count < limit) {
            val code = value.codePointAt(offset)
            val type = Character.getType(code)
            if (code == '\\'.code) result.append("\\\\")
            else if (code in 0..31 || code in 127..159 || code in 0xD800..0xDFFF ||
                type == Character.FORMAT.toInt() || type == Character.LINE_SEPARATOR.toInt() ||
                type == Character.PARAGRAPH_SEPARATOR.toInt()) result.append("\\u{").append(code.toString(16).uppercase()).append('}')
            else result.appendCodePoint(code)
            offset += Character.charCount(code); count++
        }
        if (offset < value.length) result.append('…')
        return result.toString()
    }
}

/** Pure decision validation. It creates only a summary and a one-way review
 * baseline; it cannot create a replacement document or write storage. */
object TerminalKeyRepairDecisionPlanner {
    fun make(preview: TerminalKeyRepairPreview, sessionToken: String,
        decisions: Map<Int, TerminalKeyRepairDecision>): TerminalKeyRepairDecisionPlan {
        val issues = mutableListOf<TerminalKeyRepairDecisionIssue>()
        if (preview.blockedReason != null) issues += TerminalKeyRepairDecisionIssue.SourceBlocked
        if (preview.protectedSourcePresent) issues += TerminalKeyRepairDecisionIssue.ProtectedSourceConflict
        if (preview.documentIssues.isNotEmpty()) issues += TerminalKeyRepairDecisionIssue.DocumentMetadataBlocked
        val rows = mutableListOf<TerminalKeyRepairDecisionRow>()
        val retainedGroups = mutableMapOf<Int, Int>()
        val activeGroups = mutableSetOf<Int>()
        preview.items.forEach { item ->
            val decision = decisions[item.index]
            if (decision == null) {
                issues += TerminalKeyRepairDecisionIssue.MissingDecision(item.index)
                return@forEach
            }
            when (decision.choice) {
                TerminalKeyRepairChoice.Keep -> {
                    val permitted = item.disposition == TerminalKeyRepairDisposition.KeepUnchanged ||
                        item.disposition == TerminalKeyRepairDisposition.CapacitySelectionRequired
                    if (!permitted) issues += TerminalKeyRepairDecisionIssue.InvalidChoice(item.index)
                    rows += result(item, decision.choice, null, permitted)
                    if (permitted) retain(item, retainedGroups, activeGroups)
                }
                TerminalKeyRepairChoice.Correct -> {
                    val correction = decision.correction
                    val permitted = correctable(item) && correction != null && valid(correction)
                    if (!permitted) issues += TerminalKeyRepairDecisionIssue.InvalidCorrection(item.index)
                    rows += result(item, decision.choice, correction?.takeIf { permitted }, permitted)
                    if (permitted) retain(item, retainedGroups, activeGroups, forceActive = true)
                }
                TerminalKeyRepairChoice.Exclude -> rows += result(item, decision.choice, null, false)
                TerminalKeyRepairChoice.CapacityExclude -> {
                    val permitted = TerminalKeyRepairIssue.CapacitySelectionRequired in item.issues
                    if (!permitted) issues += TerminalKeyRepairDecisionIssue.InvalidChoice(item.index)
                    rows += result(item, decision.choice, null, false)
                }
            }
        }
        retainedGroups.forEach { (group, count) ->
            if (preview.source == TerminalKeyRepairSource.AndroidLegacy && count > 1)
                issues += TerminalKeyRepairDecisionIssue.DuplicateRetainedIdentity(group)
            if (preview.source == TerminalKeyRepairSource.AppleDocument && count > 8)
                issues += TerminalKeyRepairDecisionIssue.TooManyVersions(group)
        }
        if (activeGroups.size > 64) issues += TerminalKeyRepairDecisionIssue.CapacityExceeded(activeGroups.size)
        val uniqueIssues = issues.distinct()
        val resultRows = rows.sortedBy { it.index }
        val excluded = resultRows.count { !it.included }
        val baseline = if (uniqueIssues.isEmpty()) baseline(preview, sessionToken, decisions) else null
        return TerminalKeyRepairDecisionPlan(preview.items.size, decisions.keys.count { key -> preview.items.any { it.index == key } },
            resultRows.count { it.choice == TerminalKeyRepairChoice.Keep && it.included },
            resultRows.count { it.choice == TerminalKeyRepairChoice.Correct && it.included }, excluded, activeGroups.size,
            resultRows, uniqueIssues, baseline)
    }

    private fun correctable(item: TerminalKeyRepairItem): Boolean {
        if (item.identityGroup == null) return false
        val unrepairable = setOf(TerminalKeyRepairIssue.RowNotObject, TerminalKeyRepairIssue.MissingOrWrongId,
            TerminalKeyRepairIssue.InvalidId, TerminalKeyRepairIssue.InvalidClock, TerminalKeyRepairIssue.RevisionCollision)
        return item.issues.none { it in unrepairable }
    }

    private fun valid(correction: TerminalKeyRepairCorrection) =
        TerminalCustomKeyContract.validLabel(correction.label) && correction.section in setOf("common", "symbols") &&
            TerminalCustomKeyPayload.decode(correction.payload) != null && strictUtf8Size(correction.payload) != null

    private fun retain(item: TerminalKeyRepairItem, retained: MutableMap<Int, Int>, active: MutableSet<Int>,
        forceActive: Boolean = false) {
        val group = item.identityGroup ?: return
        retained[group] = (retained[group] ?: 0) + 1
        if (forceActive || item.isActive) active += group
    }

    private fun result(item: TerminalKeyRepairItem, choice: TerminalKeyRepairChoice,
        correction: TerminalKeyRepairCorrection?, included: Boolean) = TerminalKeyRepairDecisionRow(
        item.index, choice, item.idSummary, correction?.label?.let(TerminalKeyRepairPreviewParser::safe) ?: item.labelSummary,
        correction?.section ?: item.sectionSummary,
        correction?.payload?.let(::strictUtf8Size) ?: item.payloadUtf8Bytes, included)

    private fun baseline(preview: TerminalKeyRepairPreview, sessionToken: String,
        decisions: Map<Int, TerminalKeyRepairDecision>): String {
        val canonical = StringBuilder()
        fun add(value: String) { canonical.append(value.toByteArray(Charsets.UTF_8).size).append(':').append(value).append('|') }
        add(sessionToken); add(if (preview.source == TerminalKeyRepairSource.AppleDocument) "apple" else "android")
        preview.items.sortedBy { it.index }.forEach { item ->
            add(item.index.toString()); add(item.idSummary.orEmpty()); add((item.identityGroup ?: -1).toString()); add(if (item.isActive) "1" else "0")
            decisions[item.index]?.let { decision ->
                add(decision.choice.name)
                decision.correction?.let { add(it.label); add(it.payload); add(it.section) }
            }
        }
        return MessageDigest.getInstance("SHA-256").digest(canonical.toString().toByteArray(Charsets.UTF_8))
            .take(8).joinToString("") { "%02x".format(it) }
    }

    private fun strictUtf8Size(value: String): Int? = runCatching {
        Charsets.UTF_8.newEncoder().encode(java.nio.CharBuffer.wrap(value)).remaining()
    }.getOrNull()
}
