package com.orbitterm.android.data.settings

import com.orbitterm.android.domain.session.TerminalCustomKey
import com.orbitterm.android.domain.session.TerminalCustomKeyContract
import com.orbitterm.android.domain.session.TerminalCustomKeyPayload
import com.orbitterm.android.domain.session.TerminalCustomKeySection
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.decodeFromJsonElement

/** Reading may hide unusable rows; writing must never discard those hidden rows. */
internal object TerminalCustomKeyLegacyCodec {
    @Serializable private data class Record(val id: String, val label: String, val payload: String, val section: String) {
        fun visible(): TerminalCustomKey? {
            val parsedSection = runCatching { TerminalCustomKeySection.valueOf(section) }.getOrNull() ?: return null
            if (id.isBlank() || label.isBlank() || payload.isEmpty()) return null
            return TerminalCustomKey(id, label, payload, parsedSection)
        }
    }

    fun visible(encoded: String?): List<TerminalCustomKey> =
        runCatching { records(encoded).mapNotNull { it.visible() } }.getOrDefault(emptyList())

    fun saving(encoded: String?, key: TerminalCustomKey): String {
        require(key.id.isNotBlank() && TerminalCustomKeyContract.validLabel(key.label) && TerminalCustomKeyPayload.decode(key.payload) != null)
        val current = records(encoded)
        return Json.encodeToString(current.filterNot { it.id == key.id } + Record(key.id, key.label, key.payload, key.section.name))
    }

    fun deleting(encoded: String?, id: String): String = Json.encodeToString(records(encoded).filterNot { it.id == id })

    private fun records(encoded: String?): List<Record> {
        if (encoded == null) return emptyList()
        // Unknown fields, malformed JSON, or duplicate identities block the entire
        // transaction. The caller's DataStore edit must leave the source untouched.
        val rows = try { Json.decodeFromJsonElement<List<Record>>(TerminalCustomKeyContract.parseUnambiguousJson(encoded)) }
        catch (_: IllegalArgumentException) {
            throw IllegalStateException("旧按键配置无法完整读取，已保留原数据，未保存更改。")
        }
        check(rows.map { it.id }.toSet().size == rows.size) { "旧按键配置存在重复标识，已保留原数据，未保存更改。" }
        return rows
    }
}
