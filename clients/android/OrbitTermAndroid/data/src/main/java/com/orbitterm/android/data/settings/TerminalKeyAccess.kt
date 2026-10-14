package com.orbitterm.android.data.settings

import com.orbitterm.android.domain.auth.AccountScope
import com.orbitterm.android.domain.auth.OperationGenerationProvider
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class TerminalKeyAccess @Inject constructor(private val accounts: OperationGenerationProvider) {
    data class Lease(val account: AccountScope, val generation: Long, val sequence: Long,
        val reviewToken: String = java.util.UUID.randomUUID().toString())
    private var sequence = 0L
    private val state = MutableStateFlow<Lease?>(null)
    val leases = state.asStateFlow()

    @Synchronized fun unlock(account: AccountScope) {
        if (accounts.scope.value == account) state.value = Lease(account, accounts.generation.value, ++sequence)
    }
    @Synchronized fun lock() { sequence++; state.value = null }
    @Synchronized fun renew(lease: Lease) {
        requireCurrent(lease)
        state.value = Lease(lease.account, lease.generation, ++sequence)
    }
    fun current(): Lease? = state.value?.takeIf { accounts.scope.value == it.account && accounts.generation.value == it.generation }
    fun requireCurrent(lease: Lease) {
        if (current() != lease) throw CancellationException("Terminal key access expired")
    }
}
