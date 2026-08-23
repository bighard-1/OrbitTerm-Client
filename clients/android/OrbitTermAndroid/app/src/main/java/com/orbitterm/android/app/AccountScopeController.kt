package com.orbitterm.android.app

import com.orbitterm.android.domain.auth.AccountScope
import com.orbitterm.android.domain.auth.ActiveAccountScopeProvider
import com.orbitterm.android.domain.auth.OperationGenerationProvider
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AccountScopeController @Inject constructor() : OperationGenerationProvider {
    private val mutableScope = MutableStateFlow<AccountScope?>(null)
    private val mutableGeneration = MutableStateFlow(0L)
    override val scope = mutableScope.asStateFlow()
    override val generation = mutableGeneration.asStateFlow()
    fun activate(username: String) {
        mutableGeneration.value += 1
        mutableScope.value = AccountScope.fromUsername(username)
    }
    fun deactivate() {
        mutableGeneration.value += 1
        mutableScope.value = null
    }

    /** Invalidates in-flight work at a security boundary while retaining the signed-in account. */
    fun invalidateOperations() {
        mutableGeneration.value += 1
    }
}
