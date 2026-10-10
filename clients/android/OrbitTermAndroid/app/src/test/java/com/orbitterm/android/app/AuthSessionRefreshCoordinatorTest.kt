package com.orbitterm.android.app

import com.orbitterm.android.domain.auth.AuthSession
import com.orbitterm.android.sync.AuthResponse
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AuthSessionRefreshCoordinatorTest {
    private val expired = AuthSession("user@example.com", "x.eyJleHAiOjF9.x", "old-refresh")

    @Test
    fun `concurrent callers submit a rotating refresh token only once`() = runBlocking {
        var stored: AuthSession? = expired
        var requests = 0
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val gate = RefreshSessionGate(
            read = { stored },
            replace = { old, next ->
                if (stored != old) false else { stored = next; true }
            },
            refresh = {
                requests++
                started.complete(Unit)
                release.await()
                AuthResponse(access_token = "new-access", refresh_token = "new-refresh")
            },
        )
        val foreground = async { gate.refreshIfNeeded(expired) }
        started.await()
        val worker = async { gate.refreshIfNeeded(expired) }
        release.complete(Unit)

        val foregroundResult = foreground.await()
        val workerResult = worker.await()
        assertEquals(stored, foregroundResult)
        assertEquals(stored, workerResult)
        assertEquals(1, requests)
        assertEquals("new-refresh", stored?.refreshToken)
    }

    @Test
    fun `logout during refresh cannot restore durable credentials`() = runBlocking {
        var stored: AuthSession? = expired
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val gate = RefreshSessionGate(
            read = { stored },
            replace = { old, next ->
                if (stored != old) false else { stored = next; true }
            },
            refresh = {
                started.complete(Unit)
                release.await()
                AuthResponse(access_token = "new-access", refresh_token = "new-refresh")
            },
        )
        val pending = async { gate.refreshIfNeeded(expired) }
        started.await()
        stored = null
        release.complete(Unit)

        assertNull(pending.await())
        assertNull(stored)
    }
}
