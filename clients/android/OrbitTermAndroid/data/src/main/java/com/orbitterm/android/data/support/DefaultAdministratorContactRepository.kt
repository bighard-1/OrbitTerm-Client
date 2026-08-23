package com.orbitterm.android.data.support

import com.orbitterm.android.domain.support.AdministratorContactRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Safe offline fallback. A future authenticated settings API only needs to
 * replace [refresh] and update this stream after validating its response.
 */
@Singleton
class DefaultAdministratorContactRepository @Inject constructor() : AdministratorContactRepository {
    private val mutableAdministratorEmail = MutableStateFlow(DEFAULT_ADMINISTRATOR_EMAIL)

    override val administratorEmail: StateFlow<String> = mutableAdministratorEmail

    override suspend fun refresh() = Unit

    private companion object {
        const val DEFAULT_ADMINISTRATOR_EMAIL = "orbitterm@163.com"
    }
}
