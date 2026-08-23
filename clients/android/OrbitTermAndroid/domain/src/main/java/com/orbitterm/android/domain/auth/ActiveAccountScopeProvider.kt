package com.orbitterm.android.domain.auth

import kotlinx.coroutines.flow.StateFlow

/** Data and features only need the active account partition, never app coordination details. */
interface ActiveAccountScopeProvider {
    val scope: StateFlow<AccountScope?>
}
