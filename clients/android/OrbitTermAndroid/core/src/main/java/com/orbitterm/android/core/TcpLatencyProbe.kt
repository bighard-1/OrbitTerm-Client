package com.orbitterm.android.core

import java.net.InetSocketAddress
import java.net.Socket
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.time.measureTime

/** Measures the actual Android device -> selected asset TCP handshake path. */
@Singleton
class TcpLatencyProbe @Inject constructor() {
    suspend fun measure(host: String, port: Int, timeoutMillis: Int = 2_000): Double? =
        withContext(Dispatchers.IO) {
            runCatching {
                var connected = false
                val duration = measureTime {
                    Socket().use { socket ->
                        socket.tcpNoDelay = true
                        socket.connect(InetSocketAddress(host, port), timeoutMillis)
                        connected = socket.isConnected
                    }
                }
                if (connected) duration.inWholeNanoseconds / 1_000_000.0 else null
            }.getOrNull()
        }
}

/** Failed TCP connection attempts over the recent window; this is not IP packet loss. */
fun tcpProbeFailurePercent(samples: List<Double?>): Double? =
    samples.takeIf(List<Double?>::isNotEmpty)?.let { values ->
        values.count { it == null } * 100.0 / values.size
    }

fun tcpLatencyPercentile(samples: List<Double?>, percentile: Double): Double? {
    val sorted = samples.filterNotNull().filter { it.isFinite() && it >= 0 }.sorted()
    if (sorted.isEmpty()) return null
    val index = (kotlin.math.ceil(percentile.coerceIn(0.0, 1.0) * sorted.size).toInt() - 1)
        .coerceIn(0, sorted.lastIndex)
    return sorted[index]
}
