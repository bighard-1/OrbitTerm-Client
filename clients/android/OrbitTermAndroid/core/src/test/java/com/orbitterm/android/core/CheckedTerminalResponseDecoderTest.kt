package com.orbitterm.android.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CheckedTerminalResponseDecoderTest {
    @Test
    fun `command accepts only correlated typed completion`() {
        val result = CheckedTerminalResponseDecoder.command(
            raw = success(kind = "terminal_write_completed", requestId = "request-1", channelId = 7),
            requestId = "request-1",
            expectedKind = "terminal_write_completed",
            terminalChannelId = 7,
            closedIsSuccess = false,
        )

        assertEquals(CheckedTerminalCommandResult.Completed, result)
    }

    @Test
    fun `late response cannot complete a newer request`() {
        val result = CheckedTerminalResponseDecoder.command(
            raw = success(kind = "terminal_resize_completed", requestId = "old-request", channelId = 7),
            requestId = "new-request",
            expectedKind = "terminal_resize_completed",
            terminalChannelId = 7,
            closedIsSuccess = false,
        )

        assertEquals(
            CheckedTerminalCommandResult.Failure("uncorrelated_native_response", retryable = false),
            result,
        )
    }

    @Test
    fun `duplicate close treats closed native session as completed`() {
        val result = CheckedTerminalResponseDecoder.command(
            raw = error(requestId = "request-1", code = "session_closed"),
            requestId = "request-1",
            expectedKind = "terminal_close_completed",
            terminalChannelId = 7,
            closedIsSuccess = true,
        )

        assertEquals(CheckedTerminalCommandResult.Completed, result)
    }

    @Test
    fun `malformed or legacy text never determines terminal state`() {
        val result = CheckedTerminalResponseDecoder.command(
            raw = "OK:7",
            requestId = "request-1",
            expectedKind = "terminal_write_completed",
            terminalChannelId = 7,
            closedIsSuccess = false,
        )

        assertTrue(result is CheckedTerminalCommandResult.Failure)
        assertEquals("invalid_native_response", (result as CheckedTerminalCommandResult.Failure).code)
    }

    private fun success(kind: String, requestId: String, channelId: Long): String = """
        {"schema_version":1,"request_id":"$requestId","kind":"$kind",
         "data":{"terminal_channel_id":"$channelId"},"error":null}
    """.trimIndent()

    private fun error(requestId: String, code: String): String = """
        {"schema_version":1,"request_id":"$requestId","kind":"error","data":null,
         "error":{"code":"$code","retryable":false}}
    """.trimIndent()
}
