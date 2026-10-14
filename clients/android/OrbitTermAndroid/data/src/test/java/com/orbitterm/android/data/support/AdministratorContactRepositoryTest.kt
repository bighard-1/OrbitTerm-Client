package com.orbitterm.android.data.support

import com.orbitterm.android.domain.support.AdministratorContactPolicy
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class AdministratorContactRepositoryTest {
    private class Fixture {
        var source = "https://one.invalid"
        var wall = 1_000_000L
        var uptime = 100L
        var data: String? = null
        var result: String? = "Support@EXAMPLE.COM"
        var fails = false
        var requests = 0
        fun repository(fetch: suspend () -> String? = {
            requests++
            if (fails) throw IOException()
            result
        }) = DefaultAdministratorContactRepository(source, fetch, { data }, { data = it }, { wall }, { uptime })
    }

    @Test fun refreshPersistsAndRestoresOffline() = runBlocking {
        val fixture = Fixture()
        val repository = fixture.repository()
        repository.refresh()
        repository.refresh()
        assertEquals(1, fixture.requests)
        assertEquals("Support@example.com", repository.administratorEmail.value)
        fixture.fails = true
        val restored = fixture.repository()
        restored.refresh()
        assertEquals("Support@example.com", restored.administratorEmail.value)
    }

    @Test fun invalidResponsePreservesCacheAndOmissionResetsDefault() = runBlocking {
        val fixture = Fixture()
        val repository = fixture.repository()
        repository.refresh()
        val original = fixture.data
        fixture.uptime += 301
        fixture.result = "a@example.com?bcc=b@example.com"
        repository.refresh()
        assertEquals(original, fixture.data)
        assertEquals("Support@example.com", repository.administratorEmail.value)
        fixture.uptime += 301
        fixture.result = null
        repository.refresh()
        assertEquals(AdministratorContactPolicy.DEFAULT_EMAIL, repository.administratorEmail.value)
    }

    @Test fun expiryUsesUptimeAndRejectsOtherSourceOrFutureTimestamp() = runBlocking {
        val fixture = Fixture()
        val repository = fixture.repository()
        repository.refresh()
        fixture.fails = true
        fixture.wall -= 500_000
        fixture.uptime += 301
        repository.refresh()
        assertEquals("Support@example.com", repository.administratorEmail.value)
        val futureDated = fixture.repository()
        futureDated.refresh()
        assertEquals(AdministratorContactPolicy.DEFAULT_EMAIL, futureDated.administratorEmail.value)
        fixture.uptime += 86_400
        repository.refresh()
        assertEquals(AdministratorContactPolicy.DEFAULT_EMAIL, repository.administratorEmail.value)
        fixture.source = "https://two.invalid"
        val otherSource = fixture.repository()
        otherSource.refresh()
        assertEquals(AdministratorContactPolicy.DEFAULT_EMAIL, otherSource.administratorEmail.value)
    }

    @Test fun cancelledFetchDoesNotPublishOrDelayRetry() = runBlocking {
        val fixture = Fixture()
        val began = CompletableDeferred<Unit>()
        val never = CompletableDeferred<String?>()
        var first = true
        val repository = fixture.repository {
            if (first) { first = false; began.complete(Unit); never.await() } else "new@example.com"
        }
        val request = async { repository.refresh() }
        began.await()
        request.cancelAndJoin()
        assertNull(fixture.data)
        repository.refresh()
        assertEquals("new@example.com", repository.administratorEmail.value)
    }
}
