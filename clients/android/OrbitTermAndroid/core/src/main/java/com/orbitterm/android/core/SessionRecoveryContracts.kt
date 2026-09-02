package com.orbitterm.android.core

import kotlinx.coroutines.flow.StateFlow

/**
 * A route-availability signal for interactive sessions. Unlike cloud-sync
 * reachability, this must not require Android's VALIDATED capability because a
 * legitimate SSH target may live on an isolated Wi-Fi or Ethernet network.
 */
interface SessionNetworkAvailability {
    val isNetworkUsable: StateFlow<Boolean>
}

/**
 * Stores only a process-recovery bit. Implementations must never persist a
 * server name, endpoint, account identifier, command, or terminal contents.
 */
interface LiveSessionRecoveryStore {
    val hadInterruptedSessionsAtProcessStart: Boolean
    fun markLiveSessionsPresent()
    fun clearLiveSessions()
}
