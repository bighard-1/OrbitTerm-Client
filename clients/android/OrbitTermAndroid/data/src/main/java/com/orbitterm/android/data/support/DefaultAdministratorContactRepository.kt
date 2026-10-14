package com.orbitterm.android.data.support

import android.content.Context
import android.os.SystemClock
import com.orbitterm.android.domain.support.AdministratorContactRepository
import com.orbitterm.android.domain.support.AdministratorContactPolicy
import com.orbitterm.android.sync.OrbitApi
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

/** Public policy cache, isolated by immutable service source, never by credentials. */
@Singleton
class DefaultAdministratorContactRepository internal constructor(
    private val source: String,
    private val fetch: suspend () -> String?,
    private val load: () -> String?,
    private val save: (String) -> Unit,
    private val wallNow: () -> Long,
    private val uptime: () -> Long,
) : AdministratorContactRepository {
    @Inject constructor(@ApplicationContext context: Context, api: OrbitApi) : this(
        source = api.supportContactSource,
        fetch = { api.fetchSupportContact() },
        load = { context.getSharedPreferences("support_public_contact_v1", Context.MODE_PRIVATE).getString("record", null) },
        save = { context.getSharedPreferences("support_public_contact_v1", Context.MODE_PRIVATE).edit().putString("record", it).apply() },
        wallNow = { System.currentTimeMillis() / 1000 },
        uptime = { SystemClock.elapsedRealtime() / 1000 },
    )

    @Serializable
    private data class Record(val source: String, val email: String, val fetchedAt: Long)

    private val mutableAdministratorEmail = MutableStateFlow(AdministratorContactPolicy.DEFAULT_EMAIL)
    private val mutex = Mutex()
    private var restored = false
    private var expiresAtUptime = 0L
    private var lastAttempt: Long? = null

    override val administratorEmail: StateFlow<String> = mutableAdministratorEmail

    override suspend fun refresh() = mutex.withLock {
        val now = uptime()
        if (!restored) {
            restored = true
            val record = runCatching { load()?.let { Json.decodeFromString<Record>(it) } }.getOrNull()
            if (record != null && record.source == source) {
                val email = AdministratorContactPolicy.validatedEmail(record.email)
                val wall = wallNow()
                // Compare before subtraction so corrupted Long bounds cannot overflow age.
                if (email != null && record.fetchedAt >= 0 && record.fetchedAt <= wall && wall - record.fetchedAt < LIFETIME) {
                    mutableAdministratorEmail.value = email
                    expiresAtUptime = now + LIFETIME - (wall - record.fetchedAt)
                }
            }
        }
        if (now >= expiresAtUptime) mutableAdministratorEmail.value = AdministratorContactPolicy.DEFAULT_EMAIL
        if (lastAttempt?.let { now >= it && now - it < 300 } == true) return@withLock
        lastAttempt = now
        try {
            val raw = fetch()
            currentCoroutineContext().ensureActive()
            if (uptime() >= expiresAtUptime) mutableAdministratorEmail.value = AdministratorContactPolicy.DEFAULT_EMAIL
            val email = if (raw.isNullOrEmpty()) AdministratorContactPolicy.DEFAULT_EMAIL
                else AdministratorContactPolicy.validatedEmail(raw) ?: return@withLock
            save(Json.encodeToString(Record(source, email, wallNow())))
            expiresAtUptime = uptime() + LIFETIME
            mutableAdministratorEmail.value = email
        } catch (error: CancellationException) {
            lastAttempt = null
            throw error
        } catch (_: Exception) {
            if (uptime() >= expiresAtUptime) mutableAdministratorEmail.value = AdministratorContactPolicy.DEFAULT_EMAIL
        }
    }

    private companion object { const val LIFETIME = 86_400L }
}
