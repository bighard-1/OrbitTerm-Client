package com.orbitterm.android.feature.monitor

import org.junit.Assert.assertEquals
import org.junit.Test

class RemoteProcessParserTest {
    @Test
    fun `parses bounded ps output including process name`() {
        val processes = parseRemoteProcesses(
            " 42 1 root 12.5 3.2 90 S sleep\n 77 42 app 0.1 1.0 5 R worker-thread\n",
        )

        assertEquals(2, processes.size)
        assertEquals(42, processes[0].pid)
        assertEquals(1, processes[0].parentPid)
        assertEquals("sleep", processes[0].command)
        assertEquals(12.5, processes[0].cpuPercent, 0.001)
    }

    @Test
    fun `ignores malformed process rows`() {
        assertEquals(emptyList<RemoteProcessUi>(), parseRemoteProcesses("broken row\n"))
    }
}
