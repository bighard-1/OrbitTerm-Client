package com.orbitterm.android.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Process-scoped connectivity state for foreground work.  This intentionally
 * stores no account data or secret: it only tells an unlocked UI when a retry
 * can be attempted safely.
 */
@Singleton
class NetworkAvailabilityObserver @Inject constructor(
    @ApplicationContext context: Context,
) {
    private val connectivityManager = context.getSystemService(ConnectivityManager::class.java)
    private val mutableOnline = MutableStateFlow(connectivityManager.isValidatedOnline())
    val isOnline = mutableOnline.asStateFlow()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = update(network)
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = update(network, capabilities)
        override fun onLost(network: Network) {
            mutableOnline.value = connectivityManager.isValidatedOnline()
        }
    }

    init {
        connectivityManager.registerDefaultNetworkCallback(callback)
    }

    private fun update(network: Network, capabilities: NetworkCapabilities? = null) {
        val current = capabilities ?: connectivityManager.getNetworkCapabilities(network)
        mutableOnline.value = current?.isValidatedInternet() == true
    }
}

private fun ConnectivityManager.isValidatedOnline(): Boolean =
    activeNetwork?.let(::getNetworkCapabilities)?.isValidatedInternet() == true

private fun NetworkCapabilities.isValidatedInternet(): Boolean =
    hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
        hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
