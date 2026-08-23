package com.orbitterm.android.domain.support

import kotlinx.coroutines.flow.StateFlow

/**
 * A single source of truth for the administrator contact shown in the app.
 *
 * The default implementation deliberately exposes a hot stream rather than a
 * constant. When the service-side settings endpoint is introduced, it can
 * refresh this stream without changing any Compose screen or feedback action.
 */
interface AdministratorContactRepository {
    val administratorEmail: StateFlow<String>

    suspend fun refresh()
}
