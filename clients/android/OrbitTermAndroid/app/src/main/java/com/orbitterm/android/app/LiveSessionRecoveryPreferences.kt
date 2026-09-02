package com.orbitterm.android.app

import android.content.Context
import com.orbitterm.android.core.LiveSessionRecoveryStore
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/** Process-death marker containing no user, asset, endpoint, or session data. */
@Singleton
class LiveSessionRecoveryPreferences @Inject constructor(
    @ApplicationContext context: Context,
) : LiveSessionRecoveryStore {
    private val preferences = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    override val hadInterruptedSessionsAtProcessStart: Boolean =
        preferences.getBoolean(KEY_LIVE_SESSIONS, false).also {
            // Consume the previous process marker immediately. This process will
            // write a fresh marker only after it owns a new live session.
            preferences.edit().remove(KEY_LIVE_SESSIONS).apply()
        }

    override fun markLiveSessionsPresent() {
        preferences.edit().putBoolean(KEY_LIVE_SESSIONS, true).apply()
    }

    override fun clearLiveSessions() {
        preferences.edit().remove(KEY_LIVE_SESSIONS).apply()
    }

    private companion object {
        const val PREFERENCES_NAME = "live_session_recovery"
        const val KEY_LIVE_SESSIONS = "live_sessions_present"
    }
}
