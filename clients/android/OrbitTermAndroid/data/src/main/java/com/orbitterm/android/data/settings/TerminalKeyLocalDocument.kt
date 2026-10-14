package com.orbitterm.android.data.settings

import com.orbitterm.android.domain.session.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.decodeFromJsonElement
import java.util.UUID

/** No disk writes here: callers commit the verified ciphertext and removal of
 * the old source in ONE DataStore transaction. Never fallback on decrypt failure. */
class TerminalKeyLocalDocument(private val cipher: TerminalKeyDocumentCipher, private val newActor: () -> String = { UUID.randomUUID().toString() }) {
    @Serializable
    data class Document(val version: Int, val account: String, val actor: String,
        val originalLegacy: String?, val edits: Long, val envelope: TerminalCustomKeyEnvelope)
    class MigrationBlocked : IllegalStateException("旧配置需先修复，未迁移或删除。")

    fun migrate(account: String, original: String?): String {
        val actor = newActor()
        val plan = TerminalCustomKeyMigrationPlan.inspect(original, actor)
        if (plan !is TerminalCustomKeyMigrationPlan.Result.Ready) throw MigrationBlocked()
        return seal(Document(1, account, actor, original, 0, plan.envelope))
    }

    fun read(account: String, encrypted: String): Document {
        val plaintext = cipher.decrypt(account, encrypted)
        check(plaintext.toByteArray(Charsets.UTF_8).size <= MAX_DOCUMENT_BYTES)
        val document = Json.decodeFromJsonElement<Document>(TerminalCustomKeyContract.parseUnambiguousJson(plaintext, MAX_DOCUMENT_BYTES))
        check(document.version == 1 && document.account == account && TerminalCustomKeyContract.validId(document.actor) && document.edits >= 0)
        TerminalCustomKeyContract.encode(document.envelope)
        return document
    }

    fun visible(account: String, encrypted: String): List<TerminalCustomKey> =
        TerminalCustomKeyContract.active(read(account, encrypted).envelope).map { revision ->
            val value = checkNotNull(revision.value)
            TerminalCustomKey(revision.id, value.label, value.payload,
                if (value.section == "common") TerminalCustomKeySection.Common else TerminalCustomKeySection.Symbols)
        }

    fun save(account: String, encrypted: String, key: TerminalCustomKey): String {
        val current = read(account, encrypted)
        check(TerminalCustomKeyContract.conflicts(current.envelope).none { it.id == key.id }) { "请先查看并解决此按键的冲突。" }
        val existing = current.envelope.revisions.firstOrNull { it.id == key.id }?.value
        val order = existing?.order ?: ((current.envelope.revisions.mapNotNull { it.value?.order }.maxOrNull() ?: -1) + 1)
        val value = TerminalCustomKeyValue(key.label, key.payload, if (key.section == TerminalCustomKeySection.Common) "common" else "symbols", order)
        return seal(current.copy(edits = Math.addExact(current.edits, 1), envelope =
            TerminalCustomKeyContract.replacing(current.envelope, key.id, current.actor, value)))
    }

    fun delete(account: String, encrypted: String, id: String): String {
        val current = read(account, encrypted)
        check(TerminalCustomKeyContract.conflicts(current.envelope).none { it.id == id }) { "请先查看并解决此按键的冲突。" }
        if (current.envelope.revisions.none { it.id == id && it.value != null }) return encrypted
        return seal(current.copy(edits = Math.addExact(current.edits, 1), envelope =
            TerminalCustomKeyContract.replacing(current.envelope, id, current.actor, null)))
    }

    fun resolve(account: String, encrypted: String, observed: TerminalCustomKeyConflict,
        keeping: TerminalCustomKeyRevision?): String {
        val current = read(account, encrypted)
        return seal(current.copy(edits = Math.addExact(current.edits, 1), envelope =
            TerminalCustomKeyContract.resolving(current.envelope, observed, keeping, current.actor)))
    }

    fun importRecovery(account: String, encrypted: String, plan: TerminalCustomKeyImportPlan): String {
        val current = read(account, encrypted)
        val fresh = TerminalCustomKeyImportPlan.make(current.envelope, plan.incoming)
        check(fresh.before == plan.before && fresh.merged == plan.merged) { "预览已过期，请重新导入。" }
        if (fresh.changes.isEmpty()) return encrypted
        return seal(current.copy(edits = Math.addExact(current.edits, 1), envelope = fresh.merged))
    }

    /** Refuse rollback after any edit: restoring the original would lose new work. */
    fun rollbackSource(account: String, encrypted: String): String? {
        val current = read(account, encrypted)
        check(current.edits == 0L) { "已有新更改，不能恢复迁移前快照。" }
        return current.originalLegacy
    }

    private fun seal(document: Document): String {
        TerminalCustomKeyContract.encode(document.envelope)
        val plaintext = Json.encodeToString(document)
        check(plaintext.toByteArray(Charsets.UTF_8).size <= MAX_DOCUMENT_BYTES)
        val encrypted = cipher.encrypt(document.account, plaintext)
        check(read(document.account, encrypted) == document) { "Encrypted document verification failed" }
        return encrypted
    }

    private companion object { const val MAX_DOCUMENT_BYTES = 1_048_576 }
}
