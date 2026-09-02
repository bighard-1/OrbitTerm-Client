package com.orbitterm.android.app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LiveSessionRecoveryPreferencesTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Before
    @After
    fun clearMarker() {
        context.deleteSharedPreferences("live_session_recovery")
    }

    @Test
    fun markerIsConsumedOnceByTheNextProcessOwner() {
        val firstOwner = LiveSessionRecoveryPreferences(context)
        assertFalse(firstOwner.hadInterruptedSessionsAtProcessStart)
        firstOwner.markLiveSessionsPresent()

        val recoveredOwner = LiveSessionRecoveryPreferences(context)
        assertTrue(recoveredOwner.hadInterruptedSessionsAtProcessStart)
        assertFalse(LiveSessionRecoveryPreferences(context).hadInterruptedSessionsAtProcessStart)
    }
}
