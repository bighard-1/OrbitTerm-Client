package com.orbitterm.android.data.settings

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.orbitterm.android.domain.auth.AccountScope
import com.orbitterm.android.domain.auth.OperationGenerationProvider
import com.orbitterm.android.domain.session.TerminalCustomKey
import com.orbitterm.android.domain.session.TerminalCustomKeySection
import com.orbitterm.android.domain.session.TerminalCustomKeyContract
import com.orbitterm.android.domain.session.TerminalCustomKeyRevision
import com.orbitterm.android.domain.session.TerminalCustomKeyEnvelope
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.KeyStore
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class TerminalKeyEncryptedStorageTest {
    private val context get() = ApplicationProvider.getApplicationContext<android.content.Context>()
    private val raw = """ [ {"id":"11111111-1111-1111-1111-111111111111","label":"测试","payload":"private-command\\r","section":"Common"} ] """

    @Test fun authenticatedMalformedUtf8IsRejectedInsteadOfReplacementDecoded() = runBlocking { fixture { f ->
        f.store.edit { it[f.old] = raw }
        f.access.unlock(f.account)
        f.repository().customKeys.first() // create this random fixture's key through normal migration
        val alias = "orbitterm.terminal-keys.local.v1.${f.account.storageId}"
        val key = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.getKey(alias, null)
        val native = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        native.init(javax.crypto.Cipher.ENCRYPT_MODE, key)
        native.updateAAD("OrbitTerm/terminal-keys/local/v1/${f.account.storageId}".toByteArray(Charsets.UTF_8))
        val malformed = byteArrayOf(0xc0.toByte(), 0x80.toByte())
        val encoded = java.util.Base64.getEncoder().encodeToString(byteArrayOf(1) + native.iv + native.doFinal(malformed))
        assertThrows(java.nio.charset.CharacterCodingException::class.java) {
            f.cipher.decrypt(f.account.storageId, encoded)
        }
    } }

    @Test fun rescuePreservesBothCorruptSourcesAndPausedFlagWithoutDecryptingOrWriting() = runBlocking { fixture { f ->
        val paused = androidx.datastore.preferences.core.booleanPreferencesKey("terminal_keys_migration_paused_v1_${f.account.storageId}")
        f.store.edit { it[f.old] = " [{broken"; it[f.protected] = "missing-key-ciphertext"; it[paused] = true }
        f.access.unlock(f.account)
        val before = f.store.data.first()
        val cipher = object : TerminalKeyDocumentCipher {
            override fun encrypt(account: String, plaintext: String): String = error("must not encrypt local document")
            override fun decrypt(account: String, ciphertext: String): String = error("must not require lost device key")
        }
        val repo = f.repository(cipher)
        val exported = repo.exportRescue("rescue-passphrase-2026")
        val rescued = TerminalKeyRecoveryPackage.openRescue(exported.bytes, "rescue-passphrase-2026")
        assertEquals(f.account.storageId, rescued.account)
        assertEquals("missing-key-ciphertext", String(rescued.sources.getValue(2), Charsets.UTF_16BE))
        assertEquals(" [{broken", String(rescued.sources.getValue(3), Charsets.UTF_16BE))
        assertArrayEquals(byteArrayOf(1), rescued.sources[4])
        val review = repo.inspectRescue(exported.bytes, "rescue-passphrase-2026")
        assertTrue(review.accountMatches)
        assertEquals(com.orbitterm.android.domain.session.TerminalKeyRescueStorageMatch.Exact, review.storageMatch)
        assertEquals(listOf(
            com.orbitterm.android.domain.session.TerminalKeyRescueSourceStatus.ProtectedUnreadable,
            com.orbitterm.android.domain.session.TerminalKeyRescueSourceStatus.InvalidStructure,
            com.orbitterm.android.domain.session.TerminalKeyRescueSourceStatus.PauseMarker,
        ), review.sources.map { it.status })
        assertEquals(com.orbitterm.android.domain.session.TerminalKeyRepairBlockedReason.MalformedOrAmbiguous,
            review.repairPreview?.blockedReason)
        assertTrue(review.repairPreview?.protectedSourcePresent == true)
        assertEquals(before, f.store.data.first())
        assertTrue(runCatching { repo.previewRecovery(exported.bytes, "rescue-passphrase-2026") }.isFailure)
        f.access.lock()
        assertTrue(runCatching { repo.exportRescue("rescue-passphrase-2026") }.isFailure)
        assertEquals(before, f.store.data.first())
    } }

    @Test fun rescueInspectionReportsChangedSourcesWithoutWriting() = runBlocking { fixture { f ->
        f.store.edit { it[f.old] = raw }
        f.access.unlock(f.account)
        val repo = f.repository()
        val exported = repo.exportRescue("rescue-passphrase-2026")
        f.store.edit { it[f.old] = "[]" }
        val changed = f.store.data.first()
        assertEquals(com.orbitterm.android.domain.session.TerminalKeyRescueStorageMatch.Different,
            repo.inspectRescue(exported.bytes, "rescue-passphrase-2026").also {
                assertEquals(com.orbitterm.android.domain.session.TerminalKeyRescueSourceStatus.ValidLegacyLibrary, it.sources.single().status)
                assertNull(it.repairPreview)
            }.storageMatch)
        assertEquals(changed, f.store.data.first())
    } }

    @Test fun rescueInspectionTreatsForeignSourcesAsOpaqueWithoutWriting() = runBlocking { fixture { f ->
        f.store.edit { it[f.old] = raw }
        f.access.unlock(f.account)
        val before = f.store.data.first()
        val apple = TerminalKeyRecoveryPackage.RescueSnapshot(1, f.account.storageId, mapOf(1 to byteArrayOf(0xff.toByte())))
        val foreign = f.repository().inspectRescue(
            TerminalKeyRecoveryPackage.sealRescue(apple, "rescue-passphrase-2026"), "rescue-passphrase-2026")
        assertEquals(com.orbitterm.android.domain.session.TerminalKeyRescuePlatform.Apple, foreign.platform)
        assertEquals(com.orbitterm.android.domain.session.TerminalKeyRescueStorageMatch.NotComparable, foreign.storageMatch)
        assertEquals(com.orbitterm.android.domain.session.TerminalKeyRescueSourceStatus.OpaqueForeignSource, foreign.sources.single().status)
        assertNull(foreign.repairPreview)
        assertEquals(before, f.store.data.first())
    } }

    @Test fun rescueExactLegacyAddsBoundedRepairPreviewWithoutWritingOrPayloadDisclosure() = runBlocking { fixture { f ->
        f.store.edit { it[f.old] = raw }
        f.access.unlock(f.account)
        val repo = f.repository()
        val before = f.store.data.first()
        val exported = repo.exportRescue("rescue-passphrase-2026")
        val exact = repo.inspectRescue(exported.bytes, "rescue-passphrase-2026")
        assertEquals(1, exact.repairPreview?.items?.size)
        assertEquals(com.orbitterm.android.domain.session.TerminalKeyRepairDisposition.KeepUnchanged,
            exact.repairPreview?.items?.single()?.disposition)
        assertFalse(exact.repairPreview.toString().contains("private-command"))
        assertEquals(before, f.store.data.first())
    } }

    @Test fun rescueMissingSourceDoesNotCreateEmptyLibraryOrKey() = runBlocking { fixture { f ->
        f.access.unlock(f.account)
        val before = f.store.data.first()
        assertTrue(runCatching { f.repository().exportRescue("rescue-passphrase-2026") }.isFailure)
        assertEquals(before, f.store.data.first())
        assertFalse(KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.containsAlias("orbitterm.terminal-keys.local.v1.${f.account.storageId}"))
    } }

    private suspend fun fixture(block: suspend (Fixture) -> Unit) {
        val account = AccountScope.fromUsername("key-storage-test-${UUID.randomUUID()}")
        val file = File(context.cacheDir, "key-storage-${UUID.randomUUID()}.preferences_pb")
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val store = PreferenceDataStoreFactory.create(scope = owner, produceFile = { file })
        val accounts = object : OperationGenerationProvider {
            override val scope = MutableStateFlow<AccountScope?>(account)
            override val generation = MutableStateFlow(1L)
        }
        val access = TerminalKeyAccess(accounts)
        val cipher = KeystoreTerminalKeyDocumentCipher()
        val f = Fixture(account, store, access, cipher, file, accounts, owner)
        try { withTimeout(20_000) { block(f) } }
        finally {
            f.owner.coroutineContext[Job]!!.cancelAndJoin()
            file.delete()
            // Only the randomly generated test account's key, never a user alias.
            KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("orbitterm.terminal-keys.local.v1.${account.storageId}") }
        }
    }

    private class Fixture(val account: AccountScope, var store: androidx.datastore.core.DataStore<androidx.datastore.preferences.core.Preferences>,
        val access: TerminalKeyAccess, val cipher: KeystoreTerminalKeyDocumentCipher, val file: File,
        val accounts: OperationGenerationProvider, var owner: CoroutineScope) {
        val old = stringPreferencesKey("terminal_custom_keys_${account.storageId}")
        val protected = stringPreferencesKey("terminal_keys_protected_v1_${account.storageId}")
        suspend fun reopen() {
            owner.coroutineContext[Job]!!.cancelAndJoin()
            owner = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            store = PreferenceDataStoreFactory.create(scope = owner, produceFile = { file })
        }
        fun repository(customCipher: TerminalKeyDocumentCipher = cipher) =
            DataStoreTerminalKeyUsageRepository(store, accounts, access, TerminalKeyLocalDocument(customCipher))
    }

    @Test fun migrationAtomicallyEncryptsAndReconstructsWithoutPlaintext() = runBlocking { fixture { f ->
        f.store.edit { it[f.old] = raw }
        assertTrue(f.repository().customKeys.first().isEmpty()) // locked
        assertEquals(raw, f.store.data.first()[f.old])
        f.access.unlock(f.account)
        assertEquals("private-command\\r", f.repository().customKeys.first().single().payload)
        val committed = f.store.data.first()
        assertNull(committed[f.old])
        val encrypted = committed[f.protected]!!
        assertFalse(encrypted.contains("private-command"))
        assertFalse(String(f.file.readBytes()).contains("private-command"))
        f.access.lock()
        f.reopen()
        f.access.unlock(f.account)
        val recreated = f.repository()
        assertEquals(1, recreated.customKeys.first().size)
        assertEquals(raw, TerminalKeyLocalDocument(f.cipher).read(f.account.storageId, encrypted).originalLegacy)
        f.access.lock()
        assertTrue(recreated.customKeys.first().isEmpty())
    } }

    @Test fun portableSwiftPackageImportsThroughRealKeystoreAndSurvivesReopen() = runBlocking { fixture { f ->
        f.access.unlock(f.account)
        val repo = f.repository()
        repo.customKeys.first()
        val vector = Json.parseToJsonElement(androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().context.assets
            .open("key-recovery-v1-vector.json").bufferedReader().use { it.readText() }).jsonObject
        val password = vector.getValue("password").jsonPrimitive.content
        val bytes = java.util.Base64.getDecoder().decode(vector.getValue("swift").jsonPrimitive.content)
        val before = f.store.data.first()
        val review = repo.previewRecovery(bytes, password)
        assertEquals(before, f.store.data.first())
        assertEquals(1, review.plan.changes.size)
        repo.importRecovery(review)
        val exported = repo.exportRecovery(password)
        assertFalse(String(exported.bytes, Charsets.UTF_8).contains("测试"))
        assertEquals(review.plan.merged, TerminalKeyRecoveryPackage.open(exported.bytes, password))
        f.access.lock(); f.reopen(); f.access.unlock(f.account)
        assertEquals("\\x12", f.repository().customKeys.first().single().payload)
        assertTrue(runCatching { f.repository().importRecovery(review) }.isFailure)
    } }

    @Test fun recoveryPreviewRejectsLateChangesWrongPasswordAndExpiredLease() = runBlocking { fixture { f ->
        f.access.unlock(f.account)
        val repo = f.repository()
        repo.customKeys.first()
        val vector = Json.parseToJsonElement(androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().context.assets
            .open("key-recovery-v1-vector.json").bufferedReader().use { it.readText() }).jsonObject
        val password = vector.getValue("password").jsonPrimitive.content
        val bytes = java.util.Base64.getDecoder().decode(vector.getValue("swift").jsonPrimitive.content)
        val before = f.store.data.first()
        assertTrue(runCatching { repo.previewRecovery(bytes, "$password ") }.isFailure)
        assertEquals(before, f.store.data.first())
        val review = repo.previewRecovery(bytes, password)
        repo.saveCustomKey(TerminalCustomKey("22222222-2222-2222-2222-222222222222", "local", "a", TerminalCustomKeySection.Common))
        val edited = f.store.data.first()
        assertTrue(runCatching { repo.importRecovery(review) }.isFailure)
        assertEquals(edited, f.store.data.first())
        val next = repo.previewRecovery(bytes, password)
        repo.reloadCustomKeys()
        assertTrue(runCatching { repo.importRecovery(next) }.isFailure)
        assertEquals(edited, f.store.data.first())
    } }

    @Test fun conflictReviewIsAccountLeaseBoundAndCommitsOneProtectedResolution() = runBlocking { fixture { f ->
        f.store.edit { it[f.old] = raw }
        f.access.unlock(f.account)
        val repo = f.repository()
        repo.customKeys.first()
        val docs = TerminalKeyLocalDocument(f.cipher)
        val initial = docs.read(f.account.storageId, f.store.data.first()[f.protected]!!)
        val a = initial.envelope.revisions.single()
        val b = TerminalCustomKeyRevision(a.id, mapOf("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" to 1L), null)
        val conflictDoc = initial.copy(envelope = TerminalCustomKeyEnvelope.v1(listOf(a, b)))
        f.store.edit { it[f.protected] = f.cipher.encrypt(f.account.storageId, Json.encodeToString(conflictDoc)) }
        val first = repo.customKeyState.first()
        assertTrue(first.keys.isEmpty())
        val review = first.conflicts.single()
        f.access.lock()
        assertTrue(repo.customKeyState.first().conflicts.isEmpty())
        f.access.unlock(f.account)
        val before = f.store.data.first()
        assertTrue(runCatching { repo.resolveCustomKey(review, a) }.isFailure)
        assertEquals(before, f.store.data.first())
        val fresh = repo.customKeyState.first().conflicts.single()
        repo.reloadCustomKeys()
        assertTrue(runCatching { repo.resolveCustomKey(fresh, a) }.isFailure)
        val latest = repo.customKeyState.first().conflicts.single()
        repo.resolveCustomKey(latest, a)
        val result = repo.customKeyState.first()
        assertTrue(result.conflicts.isEmpty())
        assertEquals(a.value!!.payload, result.keys.single().payload)
        val doc = docs.read(f.account.storageId, f.store.data.first()[f.protected]!!)
        assertEquals(raw, doc.originalLegacy)
        assertEquals(doc.envelope, TerminalCustomKeyContract.merge(doc.envelope, conflictDoc.envelope))
        assertTrue(runCatching { repo.resolveCustomKey(latest, null) }.isFailure)
    } }

    @Test fun explicitRetryRestartsFailedCollectorWithoutErasingOriginal() = runBlocking { fixture { f ->
        f.access.unlock(f.account)
        val valid = TerminalKeyLocalDocument(f.cipher).migrate(f.account.storageId, raw)
        f.store.edit { it[f.protected] = "damaged" }
        val repo = f.repository()
        coroutineScope {
            val failed = CompletableDeferred<Unit>()
            val observations = async {
                repo.customKeyState.onEach { if (it.keys.isEmpty()) failed.complete(Unit) }.take(2).toList()
            }
            failed.await()
            assertEquals("damaged", f.store.data.first()[f.protected])
            assertNotNull(repo.customKeyStorageNotice.first())
            f.store.edit { it[f.protected] = valid }
            repo.reloadCustomKeys()
            assertEquals(1, observations.await().last().keys.size)
            assertNull(repo.customKeyStorageNotice.first())
        }
    } }

    @Test fun failedConflictWriteLeavesEveryVersionIntact() = runBlocking { fixture { f ->
        f.access.unlock(f.account)
        val docs = TerminalKeyLocalDocument(f.cipher)
        val initial = docs.read(f.account.storageId, docs.migrate(f.account.storageId, raw))
        val a = initial.envelope.revisions.single()
        val conflictDoc = initial.copy(envelope = TerminalCustomKeyEnvelope.v1(listOf(a,
            TerminalCustomKeyRevision(a.id, mapOf("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" to 1L), null))))
        f.store.edit { it[f.protected] = f.cipher.encrypt(f.account.storageId, Json.encodeToString(conflictDoc)) }
        val failing = object : TerminalKeyDocumentCipher {
            override fun encrypt(account: String, plaintext: String): String = error("injected write failure")
            override fun decrypt(account: String, ciphertext: String) = f.cipher.decrypt(account, ciphertext)
        }
        val repo = f.repository(failing)
        val review = repo.customKeyState.first().conflicts.single()
        val before = f.store.data.first()
        assertTrue(runCatching { repo.resolveCustomKey(review, a) }.isFailure)
        assertEquals(before, f.store.data.first())
        assertEquals(review, repo.customKeyState.first().conflicts.single())
        assertTrue(repo.customKeys.first().isEmpty())
    } }

    @Test fun rollbackIsExactPausedAndRefusesToLosePostMigrationEdits() = runBlocking { fixture { f ->
        f.store.edit { it[f.old] = raw }
        f.access.unlock(f.account)
        val repo = f.repository()
        repo.customKeys.first()
        repo.rollbackUneditedMigration()
        assertEquals(raw, f.store.data.first()[f.old])
        assertNull(f.store.data.first()[f.protected])
        repo.customKeys.first()
        assertNull(f.store.data.first()[f.protected]) // no automatic remigration
    }; fixture { f ->
        f.store.edit { it[f.old] = raw }
        f.access.unlock(f.account)
        val repo = f.repository()
        repo.saveCustomKey(TerminalCustomKey("22222222-2222-2222-2222-222222222222", "新键", "x", TerminalCustomKeySection.Common))
        val before = f.store.data.first()
        assertTrue(runCatching { repo.rollbackUneditedMigration() }.isFailure)
        assertEquals(before, f.store.data.first())
        assertEquals(2, repo.customKeys.first().size)
    } }

    @Test fun lockDuringEncryptionAbortsTransactionAndPreservesOriginal() = runBlocking { fixture { f ->
        f.store.edit { it[f.old] = raw }
        f.access.unlock(f.account)
        val cipher = object : TerminalKeyDocumentCipher {
            override fun encrypt(account: String, plaintext: String): String {
                val encrypted = f.cipher.encrypt(account, plaintext)
                f.access.lock()
                return encrypted
            }
            override fun decrypt(account: String, ciphertext: String) = f.cipher.decrypt(account, ciphertext)
        }
        val repo = f.repository(cipher)
        runCatching { repo.customKeys.first() }
        assertEquals(raw, f.store.data.first()[f.old])
        assertNull(f.store.data.first()[f.protected])
    } }

    @Test fun unreadableCiphertextNeverFallsBackOrOverwritesOriginal() = runBlocking { fixture { f ->
        f.store.edit { it[f.old] = raw; it[f.protected] = "damaged" }
        f.access.unlock(f.account)
        val repo = f.repository()
        assertTrue(repo.customKeys.first().isEmpty())
        assertNotNull(repo.customKeyStorageNotice.first())
        val before = f.store.data.first()
        assertTrue(runCatching { repo.deleteCustomKey("11111111-1111-1111-1111-111111111111") }.isFailure)
        assertEquals(before, f.store.data.first())
    } }

    @Test fun keystoreRejectsTamperingAccountSwapAndMissingKeyWithoutRecreation() = runBlocking { fixture { f ->
        val encrypted = f.cipher.encrypt(f.account.storageId, "secret")
        assertNotEquals(encrypted, f.cipher.encrypt(f.account.storageId, "secret"))
        val bytes = java.util.Base64.getDecoder().decode(encrypted)
        bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
        assertTrue(runCatching { f.cipher.decrypt(f.account.storageId, java.util.Base64.getEncoder().encodeToString(bytes)) }.isFailure)
        assertTrue(runCatching { f.cipher.decrypt(AccountScope.fromUsername("different-test-account").storageId, encrypted) }.isFailure)
        fixture { other ->
            other.cipher.encrypt(other.account.storageId, "other account")
            assertTrue(runCatching { other.cipher.decrypt(other.account.storageId, encrypted) }.isFailure)
        }
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = "orbitterm.terminal-keys.local.v1.${f.account.storageId}"
        keyStore.deleteEntry(alias)
        assertTrue(runCatching { f.cipher.decrypt(f.account.storageId, encrypted) }.isFailure)
        assertFalse(keyStore.containsAlias(alias))
    } }

    @Test fun invalidLegacyIsPreservedAndNeverReportedAsMigrated() = runBlocking { fixture { f ->
        val invalid = raw.replace("private-command\\\\r", "\\\\x+F")
        assertNotEquals(raw, invalid)
        f.store.edit { it[f.old] = invalid }
        f.access.unlock(f.account)
        val repo = f.repository()
        assertEquals(1, repo.customKeys.first().size) // retained for management, not sendable
        assertEquals(invalid, f.store.data.first()[f.old])
        assertNull(f.store.data.first()[f.protected])
        assertNotNull(repo.customKeyStorageNotice.first())
    } }

    @Test fun failedCipherVerificationLeavesSourceTransactionUnchanged() = runBlocking { fixture { f ->
        f.store.edit { it[f.old] = raw }
        f.access.unlock(f.account)
        val failing = object : TerminalKeyDocumentCipher {
            override fun encrypt(account: String, plaintext: String) = f.cipher.encrypt(account, plaintext)
            override fun decrypt(account: String, ciphertext: String): String = error("injected verification failure")
        }
        assertTrue(f.repository(failing).customKeys.first().isEmpty())
        assertEquals(raw, f.store.data.first()[f.old])
        assertNull(f.store.data.first()[f.protected])
    } }
}
