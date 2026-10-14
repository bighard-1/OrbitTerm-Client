package com.orbitterm.android.data.settings

import com.orbitterm.android.domain.auth.AccountScope
import com.orbitterm.android.domain.auth.OperationGenerationProvider
import com.orbitterm.android.domain.session.TerminalCustomKey
import com.orbitterm.android.domain.session.TerminalCustomKeySection
import com.orbitterm.android.domain.session.TerminalCustomKeyContract
import com.orbitterm.android.domain.session.TerminalCustomKeyRevision
import com.orbitterm.android.domain.session.TerminalCustomKeyEnvelope
import com.orbitterm.android.domain.session.TerminalCustomKeyImportPlan
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64

class TerminalKeyLocalDocumentTest {
    private val account = AccountScope.fromUsername("test-a").storageId
    private val actor = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private val original = """ [ {"id":"11111111-1111-1111-1111-111111111111","label":"键😀","payload":"é\\r","section":"Common"} ] """
    // Deliberately not a cryptography test; real Keystore/AES tests run on the emulator.
    private val cipher = object : TerminalKeyDocumentCipher {
        override fun encrypt(account: String, plaintext: String) = account + ":" + Base64.getEncoder().encodeToString(plaintext.toByteArray())
        override fun decrypt(account: String, ciphertext: String): String {
            check(ciphertext.startsWith("$account:"))
            return String(Base64.getDecoder().decode(ciphertext.substringAfter(':')))
        }
    }

    @Test fun migrationRetainsOriginalAndActorAcrossReconstruction() {
        val first = TerminalKeyLocalDocument(cipher) { actor }
        val encrypted = first.migrate(account, original)
        val restored = TerminalKeyLocalDocument(cipher)
        assertEquals(actor, restored.read(account, encrypted).actor)
        assertEquals(original, restored.rollbackSource(account, encrypted))
        assertEquals("é\\r", restored.visible(account, encrypted).single().payload)
        assertEquals(0L, restored.read(account, encrypted).edits)
    }

    @Test fun saveDeleteKeepBackupAndBlockLossyRollback() {
        val store = TerminalKeyLocalDocument(cipher) { actor }
        val encrypted = store.migrate(account, original)
        val next = store.save(account, encrypted, TerminalCustomKey("22222222-2222-2222-2222-222222222222", "新键", "x", TerminalCustomKeySection.Symbols))
        assertEquals(original, store.read(account, next).originalLegacy)
        assertEquals(actor, store.read(account, next).actor)
        assertEquals(2, store.visible(account, next).size)
        assertThrows(IllegalStateException::class.java) { store.rollbackSource(account, next) }
        val deleted = store.delete(account, next, "11111111-1111-1111-1111-111111111111")
        assertEquals(1, store.visible(account, deleted).size)
        assertEquals(2, store.read(account, deleted).envelope.revisions.size)
        assertTrue(store.read(account, deleted).envelope.revisions.any { it.value == null })
    }

    @Test fun conflictResolutionIsExplicitPreservesBackupAndBlocksReplayOrRollback() {
        val store = TerminalKeyLocalDocument(cipher) { actor }
        val initial = store.read(account, store.migrate(account, original))
        val a = initial.envelope.revisions.single()
        val b = TerminalCustomKeyRevision(a.id, mapOf("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" to 1L), null)
        val doc = initial.copy(envelope = TerminalCustomKeyEnvelope.v1(listOf(a, b)))
        val encrypted = cipher.encrypt(account, Json.encodeToString(doc))
        assertTrue(store.visible(account, encrypted).isEmpty())
        assertThrows(IllegalStateException::class.java) { store.delete(account, encrypted, a.id) }
        assertThrows(IllegalStateException::class.java) {
            store.save(account, encrypted, TerminalCustomKey(a.id, "新键", "x", TerminalCustomKeySection.Common))
        }
        val review = TerminalCustomKeyContract.conflicts(doc.envelope).single()
        for (keep in listOf(a, null)) {
            val result = store.resolve(account, encrypted, review, keep)
            val after = store.read(account, result)
            assertEquals(original, after.originalLegacy)
            assertEquals(actor, after.actor)
            assertEquals(1L, after.edits)
            assertEquals(after.envelope, TerminalCustomKeyContract.merge(after.envelope, doc.envelope))
            assertThrows(IllegalArgumentException::class.java) { store.resolve(account, result, review, keep) }
            assertThrows(IllegalStateException::class.java) { store.rollbackSource(account, result) }
        }
    }

    @Test fun invalidLegacyAndWrongAccountNeverBecomeEmptyDocuments() {
        val store = TerminalKeyLocalDocument(cipher) { actor }
        for (raw in listOf("null", "", "{", original.replace("Common", "Future")))
            assertThrows(TerminalKeyLocalDocument.MigrationBlocked::class.java) { store.migrate(account, raw) }
        val encrypted = store.migrate(account, original)
        assertThrows(IllegalStateException::class.java) { store.read(AccountScope.fromUsername("other").storageId, encrypted) }
    }

    @Test fun encryptionVerificationFailureReturnsNoCandidate() {
        val failing = object : TerminalKeyDocumentCipher {
            override fun encrypt(account: String, plaintext: String) = "bad"
            override fun decrypt(account: String, ciphertext: String): String = error("fault")
        }
        assertThrows(IllegalStateException::class.java) { TerminalKeyLocalDocument(failing) { actor }.migrate(account, original) }
    }

    @Test fun protectedDocumentRejectsDuplicateFieldsInsteadOfChoosingWinner() {
        val store = TerminalKeyLocalDocument(cipher) { actor }
        val encrypted = store.migrate(account, original)
        val plain = cipher.decrypt(account, encrypted)
        for (ambiguous in listOf(
            plain.replace("\"version\":1", "\"version\":1,\"version\":1"),
            plain.replace("\"edits\":0", "\"edits\":1,\"\\u0065dits\":0"),
        )) {
            assertNotEquals(plain, ambiguous)
            assertThrows(IllegalArgumentException::class.java) { store.read(account, cipher.encrypt(account, ambiguous)) }
        }
    }

    @Test fun recoveryMergeKeepsActorBackupAndRejectsStalePreview() {
        val store = TerminalKeyLocalDocument(cipher) { actor }
        val encrypted = store.migrate(account, original)
        val before = store.read(account, encrypted)
        val a = before.envelope.revisions.single()
        val incoming = TerminalCustomKeyEnvelope.v1(listOf(a.copy(id = "22222222-2222-2222-2222-222222222222")))
        val plan = TerminalCustomKeyImportPlan.make(before.envelope, incoming)
        assertEquals(1, plan.changes.size); assertEquals(2, plan.activeCount)
        val after = store.read(account, store.importRecovery(account, encrypted, plan))
        assertEquals(actor, after.actor); assertEquals(original, after.originalLegacy); assertEquals(1L, after.edits)
        val changed = store.delete(account, encrypted, a.id)
        assertThrows(IllegalStateException::class.java) { store.importRecovery(account, changed, plan) }
        val stale = TerminalCustomKeyImportPlan.make(store.read(account, changed).envelope, before.envelope)
        assertTrue(stale.changes.isEmpty())
        assertEquals(changed, store.importRecovery(account, changed, stale))
    }

    @Test fun recoveryMergeRetainsConcurrentEditDeleteAndNeverSendsConflict() {
        val store = TerminalKeyLocalDocument(cipher) { actor }
        val encrypted = store.migrate(account, original)
        val before = store.read(account, encrypted)
        val a = before.envelope.revisions.single()
        val incoming = TerminalCustomKeyEnvelope.v1(listOf(a.copy(clock = mapOf("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" to 1L), value = null)))
        val plan = TerminalCustomKeyImportPlan.make(before.envelope, incoming)
        assertEquals(1, plan.conflictCount); assertEquals(0, plan.activeCount)
        val merged = store.importRecovery(account, encrypted, plan)
        assertTrue(store.visible(account, merged).isEmpty())
        assertThrows(IllegalStateException::class.java) { store.rollbackSource(account, merged) }
    }

    @Test fun leasesRejectLockReunlockAccountChangeAndSameAccountGenerationChange() {
        val accounts = object : OperationGenerationProvider {
            override val scope = MutableStateFlow<AccountScope?>(AccountScope(account))
            override val generation = MutableStateFlow(1L)
        }
        val access = TerminalKeyAccess(accounts)
        assertNull(access.current())
        access.unlock(AccountScope(account))
        val first = access.current()!!
        access.lock()
        assertThrows(CancellationException::class.java) { access.requireCurrent(first) }
        access.unlock(AccountScope(account))
        assertNotEquals(first, access.current())
        val second = access.current()!!
        accounts.generation.value++
        assertNull(access.current())
        assertThrows(CancellationException::class.java) { access.requireCurrent(second) }
        access.unlock(AccountScope(account))
        accounts.scope.value = AccountScope.fromUsername("other")
        assertNull(access.current())
        access.unlock(AccountScope(account)) // stale unlock callback
        assertNull(access.current())
    }
}
