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
}
