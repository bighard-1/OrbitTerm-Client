package com.orbitterm.android.app

import com.orbitterm.android.domain.auth.AccountScope
import com.orbitterm.android.domain.auth.OperationGenerationProvider
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test

class BiometricRequestFenceTest {
    private val accounts = object : OperationGenerationProvider {
        override val scope = MutableStateFlow<AccountScope?>(AccountScope.fromUsername("one"))
        override val generation = MutableStateFlow(1L)
    }

    @Test fun completionIsSingleUseAndOlderCallbackCannotConsumeNewPrompt() {
        val fence = BiometricRequestFence(accounts)
        val old = fence.issue(Any())!!
        val next = fence.issue(Any())!!
        assertFalse(fence.consume(old))
        assertTrue(fence.consume(next))
        assertFalse(fence.consume(next))
    }

    @Test fun lockAndSameAccountReloginRejectDelayedSuccess() {
        val fence = BiometricRequestFence(accounts)
        val beforeLock = fence.issue(Any())!!
        fence.clear()
        assertFalse(fence.consume(beforeLock))
        val beforeRelogin = fence.issue(Any())!!
        accounts.generation.value++
        assertFalse(fence.consume(beforeRelogin))
        assertTrue(fence.consume(fence.issue(Any())!!))
    }

    @Test fun accountSwitchAndSignedOutStateCannotReusePrompt() {
        val fence = BiometricRequestFence(accounts)
        val prompt = fence.issue(Any())!!
        accounts.scope.value = AccountScope.fromUsername("two")
        assertFalse(fence.consume(prompt))
        accounts.scope.value = null
        assertNull(fence.issue(Any()))
    }
}
