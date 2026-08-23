package com.orbitterm.android.feature.sftp

import org.junit.Assert.assertEquals
import org.junit.Test

class SftpInitialPathPolicyTest {
    @Test
    fun serverResolvedHomeIsUsedWithoutGuessingUsername() {
        assertEquals(listOf("/srv/chroot/alice", "/"), preferredSftpInitialPaths(" /srv/chroot/alice "))
    }

    @Test
    fun rootHomeRemainsValid() {
        assertEquals(listOf("/root", "/"), preferredSftpInitialPaths("/root"))
    }

    @Test
    fun unsafeOrMissingHomeUsesRootOnly() {
        assertEquals(listOf("/"), preferredSftpInitialPaths(null))
        assertEquals(listOf("/"), preferredSftpInitialPaths("relative/path"))
        assertEquals(listOf("/"), preferredSftpInitialPaths("/home/../root"))
    }
}
