package com.orbitterm.android.app

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.orbitterm.android.domain.auth.AccountScope
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SyncWorkAuthorityTest {
    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    private val scope = AccountScope.fromUsername("sync-authority@example.invalid")

    @After
    fun cleanUp() {
        context.getSharedPreferences("orbitterm_sync_work", android.content.Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()
    }

    @Test
    fun leaseIsInvalidAfterUnlockReplacementOrProcessReconstruction() {
        val currentProcess = SyncWorkAuthority(context)
        val firstUnlock = currentProcess.allow(scope)
        assertTrue(currentProcess.isAllowed(scope, firstUnlock))

        val secondUnlock = currentProcess.allow(scope)
        assertFalse(currentProcess.isAllowed(scope, firstUnlock))
        assertTrue(currentProcess.isAllowed(scope, secondUnlock))

        val reconstructedProcess = SyncWorkAuthority(context)
        assertFalse(reconstructedProcess.isAllowed(scope, secondUnlock))
    }
}
