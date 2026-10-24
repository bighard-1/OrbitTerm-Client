package com.orbitterm.android.sync

import org.junit.Assert.assertEquals
import org.junit.Test

class SyncVectorClockTest {
    @Test
    fun `increments only the requesting actor and keeps a canonical order`() {
        assertEquals(
            "{\"android\":3,\"ios\":4}",
            SyncVectorClock.bump("{\"ios\":4,\"android\":2}", "android"),
        )
    }

    @Test
    fun `recovers safely from malformed clocks`() {
        assertEquals("{\"android\":1}", SyncVectorClock.bump("not-json", "android"))
    }

    @Test
    fun `preserves Apple millisecond clock when Android restores a tombstone`() {
        val appleClock = 1_760_000_000_000L
        val raw = "{\"mac-device\":$appleClock,\"android\":4}"

        assertEquals(
            mapOf("mac-device" to appleClock, "android" to 4L),
            SyncVectorClock.decode(raw),
        )
        assertEquals(
            "{\"android\":5,\"mac-device\":$appleClock}",
            SyncVectorClock.bump(raw, "android"),
        )
    }

    @Test
    fun `strict coverage rejects malformed and incomplete remote clocks`() {
        val request = "{\"android\":8,\"ios\":4}"
        assertEquals(true, SyncVectorClock.strictlyCovers(request, "{\"android\":9,\"ios\":4}"))
        assertEquals(false, SyncVectorClock.strictlyCovers(request, "{\"android\":8}"))
        assertEquals(false, SyncVectorClock.strictlyCovers(request, "{\"android\":8,\"ios\":-1}"))
        assertEquals(false, SyncVectorClock.strictlyCovers(request, "{\"android\":8,\"ios\":\"4\"}"))
        assertEquals(false, SyncVectorClock.strictlyCovers(null, "{\"android\":9}"))
    }
}
