package com.orbitterm.android.feature.terminal

import com.orbitterm.android.domain.assets.NetworkDeviceProfile
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.net.InetSocketAddress
import java.net.Socket

/** Small, process-local Telnet transport. Credentials are never retained after close. */
internal class TelnetTerminalConnection(
    private val host: String,
    private val port: Int,
    private val username: String,
    private val password: String,
    private val profile: NetworkDeviceProfile,
    private val onData: (ByteArray) -> Unit,
    private val onClosed: (String?) -> Unit,
) {
    @Volatile private var socket: Socket? = null
    @Volatile private var output: BufferedOutputStream? = null
    @Volatile private var closed = false
    private val writeLock = Any()
    private var loginBuffer = ""
    private var sentUsername = false
    private var sentPassword = false
    private var sentContinue = false
    @Volatile private var lastColumns = 80
    @Volatile private var lastRows = 24

    fun connect(columns: Int, rows: Int): Boolean = runCatching {
        lastColumns = columns.coerceIn(1, 65535)
        lastRows = rows.coerceIn(1, 65535)
        val connected = Socket().apply {
            tcpNoDelay = true
            keepAlive = true
            connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MILLIS)
        }
        socket = connected
        output = BufferedOutputStream(connected.getOutputStream())
        sendWindowSize(columns, rows)
        Thread({ readLoop(connected) }, "OrbitTerm-Telnet-$host").apply {
            isDaemon = true
            start()
        }
        true
    }.getOrElse {
        closeInternal(it.localizedMessage)
        false
    }

    fun write(bytes: ByteArray) {
        if (closed || bytes.isEmpty()) return
        runCatching {
            synchronized(writeLock) {
                output?.apply { write(bytes); flush() }
            }
        }.onFailure { closeInternal(it.localizedMessage) }
    }

    fun resize(columns: Int, rows: Int) {
        lastColumns = columns.coerceIn(1, 65535)
        lastRows = rows.coerceIn(1, 65535)
        sendWindowSize(lastColumns, lastRows)
    }

    fun close() = closeInternal(null)

    private fun readLoop(connected: Socket) {
        try {
            val input = BufferedInputStream(connected.getInputStream())
            val buffer = ByteArray(64 * 1024)
            val parser = TelnetNegotiationParser(::replyNegotiation)
            while (!closed) {
                val count = input.read(buffer)
                if (count < 0) break
                val payload = parser.consume(buffer, count)
                if (payload.isNotEmpty()) {
                    onData(payload)
                    autoLogin(payload)
                }
            }
            closeInternal(null)
        } catch (error: Exception) {
            if (!closed) closeInternal(error.localizedMessage)
        }
    }

    private fun autoLogin(bytes: ByteArray) {
        if (username.isBlank() || password.isEmpty() || sentPassword && shellPrompt(loginBuffer)) return
        loginBuffer = (loginBuffer + bytes.toString(Charsets.UTF_8)).takeLast(4096)
        when {
            !sentContinue && CONTINUE_PROMPT.containsMatchIn(loginBuffer) -> {
                sentContinue = true
                write("y\r\n".toByteArray())
            }
            !sentUsername && USERNAME_PROMPT.containsMatchIn(loginBuffer) -> {
                sentUsername = true
                write((username + "\r\n").toByteArray())
            }
            !sentPassword && PASSWORD_PROMPT.containsMatchIn(loginBuffer) -> {
                sentPassword = true
                write((password + "\r\n").toByteArray())
            }
        }
    }

    private fun shellPrompt(text: String): Boolean {
        val base = SHELL_PROMPT.containsMatchIn(text)
        return when (profile) {
            NetworkDeviceProfile.mikrotikRouterOS -> base || MIKROTIK_PROMPT.containsMatchIn(text)
            NetworkDeviceProfile.paloAltoPANOS -> base || PANOS_PROMPT.containsMatchIn(text)
            else -> base
        }
    }

    private fun replyNegotiation(command: Int, option: Int) {
        val response = when (command) {
            WILL -> if (option == ECHO || option == SUPPRESS_GO_AHEAD) DO else DONT
            DO -> if (option == TERMINAL_TYPE || option == WINDOW_SIZE || option == SUPPRESS_GO_AHEAD) WILL else WONT
            else -> return
        }
        write(byteArrayOf(IAC.toByte(), response.toByte(), option.toByte()))
        if (command == DO && option == TERMINAL_TYPE) {
            write(byteArrayOf(IAC.toByte(), SB.toByte(), TERMINAL_TYPE.toByte(), 0) + "xterm-256color".toByteArray() + byteArrayOf(IAC.toByte(), SE.toByte()))
        }
        if (command == DO && option == WINDOW_SIZE) {
            sendWindowSize(lastColumns, lastRows)
        }
    }

    private fun sendWindowSize(columns: Int, rows: Int) {
        val width = columns.coerceIn(1, 65535)
        val height = rows.coerceIn(1, 65535)
        write(
            byteArrayOf(
                IAC.toByte(), SB.toByte(), WINDOW_SIZE.toByte(),
                (width ushr 8).toByte(), width.toByte(),
                (height ushr 8).toByte(), height.toByte(),
                IAC.toByte(), SE.toByte(),
            ),
        )
    }

    @Synchronized
    private fun closeInternal(reason: String?) {
        if (closed) return
        closed = true
        runCatching { socket?.close() }
        socket = null
        output = null
        onClosed(reason)
    }

    private companion object {
        const val CONNECT_TIMEOUT_MILLIS = 8_000
        const val IAC = 255
        const val WILL = 251
        const val WONT = 252
        const val DO = 253
        const val DONT = 254
        const val SB = 250
        const val SE = 240
        const val ECHO = 1
        const val SUPPRESS_GO_AHEAD = 3
        const val TERMINAL_TYPE = 24
        const val WINDOW_SIZE = 31
        val USERNAME_PROMPT = Regex("(?im)(^|\\r|\\n)\\s*(username|login|user name|user|account|用户名|账号)\\s*[:：]\\s*$")
        val PASSWORD_PROMPT = Regex("(?im)(^|\\r|\\n).*?(password|passwd|passcode|口令|密码).*?[:：]\\s*$")
        val CONTINUE_PROMPT = Regex("(?im)(press any key|hit any key|按任意键|continue\\?|are you sure|yes/no|y/n|是否继续)")
        val SHELL_PROMPT = Regex("(?m)(^|\\r|\\n)(\\s*<[^>\\r\\n]+>|\\s*\\[[^\\]\\r\\n]+\\]|[A-Za-z0-9_.()/:@-]{1,96})\\s*[>#]\\s*$")
        val MIKROTIK_PROMPT = Regex("(?m)(^|\\r|\\n)\\[[^\\]\\r\\n]+@[^\\]\\r\\n]+\\]\\s*>\\s*$")
        val PANOS_PROMPT = Regex("(?m)(^|\\r|\\n)[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+[>#]\\s*$")
    }
}

internal class TelnetNegotiationParser(
    private val onNegotiation: (command: Int, option: Int) -> Unit,
) {
    private var state = 0
    private var command = 0
    private var subNegotiationSawIac = false

    fun consume(source: ByteArray, length: Int): ByteArray {
        val output = ArrayList<Byte>(length)
        for (index in 0 until length) {
            val value = source[index].toInt() and 0xff
            when (state) {
                0 -> if (value == 255) state = 1 else output += source[index]
                1 -> when (value) {
                    255 -> { output += 255.toByte(); state = 0 }
                    251, 252, 253, 254 -> { command = value; state = 2 }
                    250 -> { state = 3; subNegotiationSawIac = false }
                    else -> state = 0
                }
                2 -> { onNegotiation(command, value); state = 0 }
                3 -> {
                    if (subNegotiationSawIac && value == 240) state = 0
                    subNegotiationSawIac = value == 255
                }
            }
        }
        return output.toByteArray()
    }
}
