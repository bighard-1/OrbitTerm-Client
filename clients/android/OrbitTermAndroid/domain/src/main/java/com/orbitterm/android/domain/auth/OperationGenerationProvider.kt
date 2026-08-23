package com.orbitterm.android.domain.auth

import kotlinx.coroutines.flow.StateFlow

interface OperationGenerationProvider : ActiveAccountScopeProvider {
    val generation: StateFlow<Long>
}
