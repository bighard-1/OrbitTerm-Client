package com.orbitterm.android.data.settings

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.MutablePreferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.orbitterm.android.domain.auth.OperationGenerationProvider
import com.orbitterm.android.domain.auth.AccountScope
import com.orbitterm.android.domain.session.TerminalKeyUsageRepository
import com.orbitterm.android.domain.session.TerminalCustomKey
import com.orbitterm.android.domain.session.TerminalCustomKeyContract
import com.orbitterm.android.domain.session.TerminalCustomKeyConflictReview
import com.orbitterm.android.domain.session.TerminalCustomKeyRevision
import com.orbitterm.android.domain.session.TerminalCustomKeyState
import com.orbitterm.android.domain.session.TerminalCustomKeySection
import com.orbitterm.android.domain.session.TerminalCustomKeyExport
import com.orbitterm.android.domain.session.TerminalCustomKeyImportReview
import com.orbitterm.android.domain.session.TerminalCustomKeyImportPlan
import com.orbitterm.android.domain.session.TerminalKeyRescuePlatform
import com.orbitterm.android.domain.session.TerminalKeyRescueReview
import com.orbitterm.android.domain.session.TerminalKeyRescueSourceReview
import com.orbitterm.android.domain.session.TerminalKeyRescueSourceStatus
import com.orbitterm.android.domain.session.TerminalKeyRescueStorageMatch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.first
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

private val Context.terminalKeyUsageDataStore by preferencesDataStore(name = "terminal_key_usage")

@Singleton
class DataStoreTerminalKeyUsageRepository(
    private val store: DataStore<Preferences>,
    private val accountScopeController: OperationGenerationProvider,
    private val access: TerminalKeyAccess,
    private val documents: TerminalKeyLocalDocument,
) : TerminalKeyUsageRepository {
    @Inject constructor(@ApplicationContext context: Context, accounts: OperationGenerationProvider,
        access: TerminalKeyAccess, cipher: KeystoreTerminalKeyDocumentCipher) :
        this(context.terminalKeyUsageDataStore, accounts, access, TerminalKeyLocalDocument(cipher))

    private val notice = MutableStateFlow<Pair<TerminalKeyAccess.Lease, String>?>(null)
    private val unlockedLease = combine(accountScopeController.scope, accountScopeController.generation,
        access.leases) { _, _, _ -> access.current() }.distinctUntilChanged()
    override val customKeyStorageNotice: Flow<String?> = combine(notice, access.leases,
        accountScopeController.generation, accountScopeController.scope) { message, _, _, _ ->
        message?.takeIf { access.current() == it.first }?.second
    }
    @OptIn(ExperimentalCoroutinesApi::class)
    override val usageCounts: Flow<Map<String, Int>> = unlockedLease.flatMapLatest { lease ->
        lease?.let { usageForScope(it.account) } ?: flowOf(emptyMap())
    }
    @OptIn(ExperimentalCoroutinesApi::class)
    override val customKeyState: Flow<TerminalCustomKeyState> = unlockedLease.flatMapLatest { lease ->
            if (lease == null) flowOf(TerminalCustomKeyState()) else flow {
                notice.value = null
                store.edit { ensureProtected(it, lease) }
                access.requireCurrent(lease)
                // Usage counters share this DataStore. Do not decrypt/merge the
                // whole key library again for every key press.
                emitAll(store.data.map { preferences ->
                    preferences[Keys.protected(lease.account)] to preferences[Keys.customKeys(lease.account)]
                }.distinctUntilChanged().map { (encrypted, legacy) ->
                    access.requireCurrent(lease)
                    val snapshot = if (encrypted != null) {
                        val envelope = documents.read(lease.account.storageId, encrypted).envelope
                        TerminalCustomKeyState(
                            TerminalCustomKeyContract.active(envelope).map { row ->
                                val value = checkNotNull(row.value)
                                TerminalCustomKey(row.id, value.label, value.payload,
                                    if (value.section == "common") TerminalCustomKeySection.Common else TerminalCustomKeySection.Symbols)
                            },
                            TerminalCustomKeyContract.conflicts(envelope).map { TerminalCustomKeyConflictReview(lease.reviewToken, it) },
                        )
                    } else TerminalCustomKeyState(TerminalCustomKeyLegacyCodec.visible(legacy))
                    access.requireCurrent(lease)
                    snapshot
                })
            }.catch { error ->
                if (error is CancellationException) throw error
                if (access.current() == lease) notice.value = lease to "无法读取加密按键配置，原数据已保留。请勿清除应用数据。"
                emit(TerminalCustomKeyState())
            }
        }

    override val customKeys: Flow<List<TerminalCustomKey>> = customKeyState.map { it.keys }

    override suspend fun reloadCustomKeys() {
        val lease = checkNotNull(access.current())
        // Rotate the in-memory lease to restart a failed read and invalidate old reviews.
        access.renew(lease)
    }

    override fun recoveryAccessValid(token: String) = access.current()?.reviewToken == token
    override fun recoveryAccessToken() = access.current()?.reviewToken
    override val recoveryAccessTokens: Flow<String?> = unlockedLease.map { it?.reviewToken }

    override suspend fun exportRescue(password: String): TerminalCustomKeyExport = withContext(Dispatchers.Default) {
        val lease = checkNotNull(access.current())
        val before = rawSourceState(store.data.first(), lease.account)
        access.requireCurrent(lease)
        check(before.first != null || before.second != null) { "没有可读取的原始配置，未生成救援文件。" }
        // Preserve every UTF-16 code unit, including malformed surrogate pairs.
        // Do not decrypt, migrate, normalize, or parse unknown source documents.
        val sources = linkedMapOf<Int, ByteArray>()
        check(listOfNotNull(before.first, before.second).sumOf { it.length.toLong() * 2 } + 1 <= 4 * 1024 * 1024)
        before.first?.let { sources[2] = rawUtf16(it) }
        before.second?.let { sources[3] = rawUtf16(it) }
        before.third?.let { sources[4] = byteArrayOf(if (it) 1 else 0) }
        val bytes = try { TerminalKeyRecoveryPackage.sealRescue(
            TerminalKeyRecoveryPackage.RescueSnapshot(2, lease.account.storageId, sources), password)
        } finally { sources.values.forEach { it.fill(0) } }
        access.requireCurrent(lease)
        check(rawSourceState(store.data.first(), lease.account) == before) { "配置已变化，请重新导出。" }
        access.requireCurrent(lease)
        TerminalCustomKeyExport(lease.reviewToken, bytes)
    }

    override suspend fun inspectRescue(bytes: ByteArray, password: String): TerminalKeyRescueReview = withContext(Dispatchers.Default) {
        val lease = checkNotNull(access.current())
        val before = rawSourceState(store.data.first(), lease.account)
        val snapshot = TerminalKeyRecoveryPackage.openRescue(bytes, password)
        try {
        access.requireCurrent(lease)
        val accountMatches = snapshot.account == lease.account.storageId
        val current = rescueSnapshot(lease.account, before)
        val storageMatch = try {
            when {
                snapshot.platform != 2 -> TerminalKeyRescueStorageMatch.NotComparable
                current == null -> TerminalKeyRescueStorageMatch.Missing
                sameSnapshot(snapshot, current) -> TerminalKeyRescueStorageMatch.Exact
                else -> TerminalKeyRescueStorageMatch.Different
            }
        } finally {
            current?.sources?.values?.forEach { it.fill(0) }
        }
        val sources = snapshot.sources.toSortedMap().map { (tag, source) ->
            val status = when {
                snapshot.platform != 2 -> TerminalKeyRescueSourceStatus.OpaqueForeignSource
                tag == 2 -> {
                    if (!accountMatches) TerminalKeyRescueSourceStatus.OpaqueForeignSource
                    else runCatching { documents.read(snapshot.account, strictUtf16(source)) }.fold(
                        onSuccess = { TerminalKeyRescueSourceStatus.ValidProtectedLibrary },
                        onFailure = { TerminalKeyRescueSourceStatus.ProtectedUnreadable })
                }
                tag == 3 -> when (val inspection = TerminalCustomKeyMigrationPlan.inspect(strictUtf16(source), INSPECTION_ACTOR)) {
                    is TerminalCustomKeyMigrationPlan.Result.Ready -> TerminalKeyRescueSourceStatus.ValidLegacyLibrary
                    is TerminalCustomKeyMigrationPlan.Result.Blocked -> when (inspection.reason) {
                        TerminalCustomKeyMigrationPlan.Reason.INVALID_SOURCE -> TerminalKeyRescueSourceStatus.InvalidStructure
                        TerminalCustomKeyMigrationPlan.Reason.DUPLICATE_ID -> TerminalKeyRescueSourceStatus.DuplicateId
                        TerminalCustomKeyMigrationPlan.Reason.CONTRACT_REJECTED -> TerminalKeyRescueSourceStatus.ContractRejected
                    }
                }
                else -> TerminalKeyRescueSourceStatus.PauseMarker
            }
            TerminalKeyRescueSourceReview(tag, source.size, status)
        }
        // A repair preview is meaningful only while the authenticated rescue source is
        // still byte-for-byte identical to the current account's local source. Protected
        // ciphertext remains opaque here; only the structurally enumerable legacy field
        // is diagnosed, and no replacement document is created.
        val repairPreview = snapshot.sources[3]?.takeIf {
            snapshot.platform == 2 && accountMatches && storageMatch == TerminalKeyRescueStorageMatch.Exact
        }?.let { legacy ->
            TerminalKeyRepairPreviewParser.androidLegacy(strictUtf16(legacy), snapshot.sources.containsKey(2))
        }
        access.requireCurrent(lease)
        check(rawSourceState(store.data.first(), lease.account) == before) { "当前配置已变化，请重新核验。" }
        TerminalKeyRescueReview(lease.reviewToken,
            if (snapshot.platform == 1) TerminalKeyRescuePlatform.Apple else TerminalKeyRescuePlatform.Android,
            accountMatches, storageMatch, sources, repairPreview, java.util.UUID.randomUUID().toString())
        } finally {
            snapshot.sources.values.forEach { it.fill(0) }
        }
    }

    private fun rawSourceState(preferences: Preferences, account: AccountScope): Triple<String?, String?, Boolean?> = Triple(
        preferences[Keys.protected(account)], preferences[Keys.customKeys(account)], preferences[Keys.paused(account)])

    private fun rescueSnapshot(account: AccountScope, source: Triple<String?, String?, Boolean?>): TerminalKeyRecoveryPackage.RescueSnapshot? {
        if (source.first == null && source.second == null) return null
        val entries = linkedMapOf<Int, ByteArray>()
        source.first?.let { entries[2] = rawUtf16(it) }
        source.second?.let { entries[3] = rawUtf16(it) }
        source.third?.let { entries[4] = byteArrayOf(if (it) 1 else 0) }
        return TerminalKeyRecoveryPackage.RescueSnapshot(2, account.storageId, entries)
    }

    private fun rawUtf16(value: String): ByteArray = java.nio.ByteBuffer.allocate(value.length * 2).also { buffer ->
        value.forEach(buffer::putChar)
    }.array()

    private fun sameSnapshot(left: TerminalKeyRecoveryPackage.RescueSnapshot,
        right: TerminalKeyRecoveryPackage.RescueSnapshot): Boolean =
        left.platform == right.platform && left.account == right.account && left.sources.keys == right.sources.keys &&
            left.sources.all { (tag, bytes) -> bytes.contentEquals(right.sources.getValue(tag)) }

    private fun strictUtf16(bytes: ByteArray): String {
        check(bytes.size % 2 == 0)
        val buffer = java.nio.ByteBuffer.wrap(bytes)
        return String(CharArray(bytes.size / 2) { buffer.char })
    }

    override suspend fun exportRecovery(password: String): TerminalCustomKeyExport = withContext(Dispatchers.Default) {
        val lease = checkNotNull(access.current())
        val encrypted = checkNotNull(store.data.first()[Keys.protected(lease.account)]) { "请先重试读取；无效旧配置不能导出为有效按键库。" }
        val doc = documents.read(lease.account.storageId, encrypted)
        val bytes = TerminalKeyRecoveryPackage.seal(doc.envelope, password)
        access.requireCurrent(lease)
        check(store.data.first()[Keys.protected(lease.account)] == encrypted) { "配置已变化，请重新导出。" }
        TerminalCustomKeyExport(lease.reviewToken, bytes)
    }

    override suspend fun previewRecovery(bytes: ByteArray, password: String): TerminalCustomKeyImportReview = withContext(Dispatchers.Default) {
        val lease = checkNotNull(access.current())
        val encrypted = checkNotNull(store.data.first()[Keys.protected(lease.account)]) { "请先重试读取；不能覆盖未知或损坏的旧配置。" }
        val doc = documents.read(lease.account.storageId, encrypted)
        val incoming = TerminalKeyRecoveryPackage.open(bytes, password)
        val plan = TerminalCustomKeyImportPlan.make(doc.envelope, incoming)
        access.requireCurrent(lease)
        check(store.data.first()[Keys.protected(lease.account)] == encrypted) { "配置已变化，请重新导入。" }
        TerminalCustomKeyImportReview(lease.reviewToken, fingerprint(encrypted), plan)
    }

    override suspend fun importRecovery(review: TerminalCustomKeyImportReview) {
        val lease = checkNotNull(access.current())
        check(lease.reviewToken == review.accessToken) { "预览已过期，请重新导入。" }
        store.edit { preferences ->
            access.requireCurrent(lease)
            val encrypted = checkNotNull(preferences[Keys.protected(lease.account)])
            check(fingerprint(encrypted) == review.storageFingerprint) { "配置已变化，请重新导入。" }
            preferences[Keys.protected(lease.account)] = documents.importRecovery(lease.account.storageId, encrypted, review.plan)
            access.requireCurrent(lease)
        }
        access.requireCurrent(lease)
    }

    private fun fingerprint(encrypted: String): String = java.security.MessageDigest.getInstance("SHA-256")
        .digest(encrypted.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    override suspend fun resolveCustomKey(review: TerminalCustomKeyConflictReview, keeping: TerminalCustomKeyRevision?) {
        val lease = checkNotNull(access.current()) { "按键配置尚未解锁。" }
        check(review.accessToken == lease.reviewToken) { "此冲突页面已过期，请重新读取。" }
        store.edit { preferences ->
            access.requireCurrent(lease)
            val encrypted = checkNotNull(preferences[Keys.protected(lease.account)])
            preferences[Keys.protected(lease.account)] = documents.resolve(lease.account.storageId, encrypted, review.conflict, keeping)
            access.requireCurrent(lease)
        }
        access.requireCurrent(lease)
    }

    override suspend fun recordUse(keyLabel: String) {
        val lease = access.current() ?: return
        val scope = lease.account
        store.edit { preferences ->
            access.requireCurrent(lease)
            val current = preferences[Keys.usage(scope)]
                ?.let { encoded -> runCatching { Json.decodeFromString<Map<String, Int>>(encoded) }.getOrNull() }
                .orEmpty()
            val nextCount = (current[keyLabel] ?: 0).coerceAtMost(MAX_USAGE_COUNT - 1) + 1
            preferences[Keys.usage(scope)] = Json.encodeToString(current + (keyLabel to nextCount))
            access.requireCurrent(lease)
        }
    }

    override suspend fun saveCustomKey(key: TerminalCustomKey) {
        val lease = checkNotNull(access.current()) { "按键配置尚未解锁。" }
        store.edit { preferences ->
            val encrypted = ensureProtected(preferences, lease)
            if (encrypted == null) preferences[Keys.customKeys(lease.account)] =
                TerminalCustomKeyLegacyCodec.saving(preferences[Keys.customKeys(lease.account)], key)
            else preferences[Keys.protected(lease.account)] = documents.save(lease.account.storageId, encrypted, key)
            access.requireCurrent(lease)
        }
        access.requireCurrent(lease)
    }

    override suspend fun deleteCustomKey(id: String) {
        val lease = checkNotNull(access.current()) { "按键配置尚未解锁。" }
        store.edit { preferences ->
            val encrypted = ensureProtected(preferences, lease)
            if (encrypted == null) preferences[Keys.customKeys(lease.account)] =
                TerminalCustomKeyLegacyCodec.deleting(preferences[Keys.customKeys(lease.account)], id)
            else preferences[Keys.protected(lease.account)] = documents.delete(lease.account.storageId, encrypted, id)
            access.requireCurrent(lease)
        }
        access.requireCurrent(lease)
    }

    private fun usageForScope(scope: AccountScope): Flow<Map<String, Int>> =
        store.data.map { preferences ->
            preferences[Keys.usage(scope)]
                ?.let { encoded -> runCatching { Json.decodeFromString<Map<String, Int>>(encoded) }.getOrNull() }
                .orEmpty()
        }

    /** Explicit recovery operation, never triggered automatically on a read error. */
    suspend fun rollbackUneditedMigration() {
        val lease = checkNotNull(access.current())
        store.edit { preferences ->
            access.requireCurrent(lease)
            val encrypted = checkNotNull(preferences[Keys.protected(lease.account)])
            val original = documents.rollbackSource(lease.account.storageId, encrypted)
            if (original == null) preferences.remove(Keys.customKeys(lease.account))
            else preferences[Keys.customKeys(lease.account)] = original
            preferences.remove(Keys.protected(lease.account))
            preferences[Keys.paused(lease.account)] = true
            access.requireCurrent(lease)
        }
        access.requireCurrent(lease)
    }

    private fun ensureProtected(preferences: MutablePreferences, lease: TerminalKeyAccess.Lease): String? {
        access.requireCurrent(lease)
        preferences[Keys.protected(lease.account)]?.let {
            // Every consumer reads strictly. Presence must win even if decryption
            // will fail; never regenerate from the legacy source on that failure.
            return it
        }
        if (preferences[Keys.paused(lease.account)] == true) {
            notice.value = lease to "按键迁移已回滚，原配置保留在旧存储中。"
            return null
        }
        val encrypted = try { documents.migrate(lease.account.storageId, preferences[Keys.customKeys(lease.account)]) }
        catch (_: TerminalKeyLocalDocument.MigrationBlocked) {
            notice.value = lease to "部分旧按键需先修复，暂未迁移至加密存储；原配置未删除。"
            return null
        }
        access.requireCurrent(lease)
        preferences[Keys.protected(lease.account)] = encrypted
        preferences.remove(Keys.customKeys(lease.account))
        notice.value = null
        return encrypted
    }

    private object Keys {
        fun usage(scope: AccountScope) = stringPreferencesKey("terminal_key_usage_${scope.storageId}")
        fun customKeys(scope: AccountScope) = stringPreferencesKey("terminal_custom_keys_${scope.storageId}")
        fun protected(scope: AccountScope) = stringPreferencesKey("terminal_keys_protected_v1_${scope.storageId}")
        fun paused(scope: AccountScope) = booleanPreferencesKey("terminal_keys_migration_paused_v1_${scope.storageId}")
    }

    private companion object {
        const val MAX_USAGE_COUNT = 10_000
        const val INSPECTION_ACTOR = "00000000-0000-0000-0000-000000000001"
    }
}
