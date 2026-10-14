package com.orbitterm.android.domain.support

import kotlinx.coroutines.flow.StateFlow

/**
 * A single source of truth for the administrator contact shown in the app.
 *
 * The public recovery-info endpoint supplies this value. Cache entries are
 * service-source scoped; no account token or recovery-policy claims are stored.
 */
interface AdministratorContactRepository {
    val administratorEmail: StateFlow<String>

    suspend fun refresh()
}
