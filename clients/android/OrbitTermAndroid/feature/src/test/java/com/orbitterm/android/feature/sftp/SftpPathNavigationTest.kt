package com.orbitterm.android.feature.sftp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SftpPathNavigationTest {
    @Test
    fun absolutePathsAreNormalizedBeforeTheyReachTheCheckedClient() {
        assertEquals("/var/log", "/var//log/".normalizeRemoteNavigationPath())
        assertEquals("/", "/".normalizeRemoteNavigationPath())
    }

    @Test
    fun relativeTraversalAndWindowsStylePathsAreRejected() {
        assertNull("var/log".normalizeRemoteNavigationPath())
        assertNull("/var/../etc".normalizeRemoteNavigationPath())
        assertNull("/var\\log".normalizeRemoteNavigationPath())
    }
}
