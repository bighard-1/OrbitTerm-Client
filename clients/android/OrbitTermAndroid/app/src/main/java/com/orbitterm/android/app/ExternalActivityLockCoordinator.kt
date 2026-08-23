package com.orbitterm.android.app

import android.os.SystemClock
import javax.inject.Inject
import javax.inject.Singleton
import com.orbitterm.android.core.DocumentInteractionCoordinator

/**
 * Distinguishes a user-initiated system document picker from an ordinary app
 * background transition. The host activity applies a bounded grace period,
 * then locks if the picker never returns.
 */
@Singleton
class ExternalActivityLockCoordinator @Inject constructor() : DocumentInteractionCoordinator {
    private var startedAtMillis: Long? = null

    override fun beginDocumentInteraction() {
        startedAtMillis = SystemClock.elapsedRealtime()
    }

    fun resumeHost() {
        startedAtMillis = null
    }

    fun isDocumentInteractionPending(): Boolean = startedAtMillis != null

    fun isDocumentInteractionExpired(graceMillis: Long): Boolean =
        startedAtMillis?.let { SystemClock.elapsedRealtime() - it >= graceMillis } ?: false
}
