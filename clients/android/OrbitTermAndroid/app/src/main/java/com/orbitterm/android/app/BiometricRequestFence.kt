package com.orbitterm.android.app

import com.orbitterm.android.domain.auth.AccountScope
import com.orbitterm.android.domain.auth.OperationGenerationProvider

/** Main-thread request ownership, independent of platform Cipher for unit tests. */
internal class BiometricRequestFence(private val accounts: OperationGenerationProvider) {
    private var request: Any? = null
    private var account: AccountScope? = null
    private var generation = -1L

    fun <T : Any> issue(value: T?): T? {
        clear()
        val current = accounts.scope.value ?: return null
        if (value == null) return null
        request = value
        account = current
        generation = accounts.generation.value
        return value
    }

    fun consume(value: Any): Boolean {
        // An obsolete callback must not consume a newer prompt's request.
        if (request !== value) return false
        val accepted = account == accounts.scope.value && generation == accounts.generation.value
        clear()
        return accepted
    }

    fun clear() { request = null; account = null; generation = -1L }
}
