package com.orbitterm.android.feature.terminal

import com.orbitterm.android.core.CheckedTerminalNativeClient
import com.orbitterm.android.core.CheckedTerminalCommandResult
import com.orbitterm.android.core.CheckedTerminalOpenResult
import com.orbitterm.android.core.CheckedSshNativeClient
import com.orbitterm.android.core.NativeTerminalOutputRouter
import com.orbitterm.android.core.OrbitCoreBridge
import com.orbitterm.android.core.SessionForegroundController
import com.orbitterm.android.core.LiveSessionRecoveryStore
import com.orbitterm.android.domain.performance.FrameInvalidationBatcher
import com.orbitterm.android.domain.performance.RuntimeResourceBudget
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.LinkedHashMap
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import com.orbitterm.android.domain.assets.ServerAsset
import com.orbitterm.android.domain.assets.ServerCredentials
import com.orbitterm.android.domain.assets.ServerTransportProtocol
import com.orbitterm.android.domain.assets.NetworkDeviceProfile
import javax.inject.Inject
import javax.inject.Singleton

data class ActiveTerminalSession(
    val id: String,
    val assetId: String,
    val displayName: String,
    val baseSessionId: Long,
    val terminalChannelId: Long,
    val transport: String = ServerTransportProtocol.ssh.name,
    val engine: RemoteTerminalEngine,
    val connectionState: TerminalSessionConnectionState = TerminalSessionConnectionState.Connected,
    val revision: Long = 0,
    /** Most-recent-first commands sent as complete lines through OrbitTerm controls. */
    val commandHistory: List<String> = emptyList(),
)

/** Owns only live, checked terminal channels for the lifetime of the process. */
@Singleton
class TerminalSessionController @Inject constructor(
    private val nativeClient: CheckedTerminalNativeClient,
    private val checkedSsh: CheckedSshNativeClient,
    private val foregroundSessions: SessionForegroundController,
    private val recoveryStore: LiveSessionRecoveryStore,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val sessions = MutableStateFlow<List<ActiveTerminalSession>>(emptyList())
    private val mutableSelectedSessionId = MutableStateFlow<String?>(null)
    private val pendingOutputByChannel = LinkedHashMap<Long, PendingTerminalOutput>()
    private val pendingRenderChannels = FrameInvalidationBatcher<Long>(
        RuntimeResourceBudget.TERMINAL_MAX_PENDING_RENDER_CHANNELS,
    )
    private var renderFlushJob: Job? = null
    /** Invalidates terminal-open requests started before a lock, logout, or account switch. */
    private var sessionGeneration = 0L
    private val telnetConnections = mutableMapOf<String, TelnetTerminalConnection>()
    private val nextTelnetChannelId = AtomicLong(-1L)
    val activeSessions: StateFlow<List<ActiveTerminalSession>> = sessions.asStateFlow()
    /** The workspace selected by the user; tool screens use this rather than creation order. */
    val selectedSessionId: StateFlow<String?> = mutableSelectedSessionId.asStateFlow()
    val hadInterruptedSessionsAtProcessStart: Boolean = recoveryStore.hadInterruptedSessionsAtProcessStart

    init {
        scope.launch {
            NativeTerminalOutputRouter.output.collect { output ->
                val currentSession = sessions.value.firstOrNull {
                    it.terminalChannelId == output.terminalChannelId
                }
                if (currentSession == null) {
                    bufferEarlyOutput(output)
                    return@collect
                }
                currentSession.engine.append(output.bytes)
                scheduleRenderInvalidation(currentSession.terminalChannelId)
            }
        }
    }

    suspend fun open(
        assetId: String,
        displayName: String,
        baseSessionId: Long,
        columns: Int = DEFAULT_COLUMNS,
        rows: Int = DEFAULT_ROWS,
        shouldAttach: () -> Boolean = { true },
    ): Boolean {
        if (!OrbitCoreBridge.isTerminalOutputCallbackInstalled) return false
        val generationAtRequestStart = sessionGeneration
        val result = withContext(Dispatchers.IO) { nativeClient.open(baseSessionId, columns, rows) }
        val opened = result as? CheckedTerminalOpenResult.Opened ?: return false
        if (generationAtRequestStart != sessionGeneration || !shouldAttach()) {
            // A security boundary was crossed while the native channel was opening.
            // Never attach a late channel to a locked, switched, or superseded UI.
            withContext(Dispatchers.IO) {
                nativeClient.close(opened.terminalChannelId)
                checkedSsh.disconnect(baseSessionId)
            }
            NativeTerminalOutputRouter.retire(opened.terminalChannelId)
            pendingOutputByChannel.remove(opened.terminalChannelId)
            return false
        }
        val engine = RemoteTerminalEngine(columns, rows, onInput = { bytes ->
            scope.launch(Dispatchers.IO) {
                handleTerminalCommandResult(opened.terminalChannelId, nativeClient.write(opened.terminalChannelId, bytes))
            }
        })
        val terminalSessionId = UUID.randomUUID().toString()
        // Publish the engine before enabling callback delivery. A server may emit
        // its welcome prompt while open() is returning; previously that narrow
        // interval could leave output in the early buffer after it was drained.
        // The session is now always ready to receive either buffered or live data.
        sessions.value = sessions.value + ActiveTerminalSession(
            id = terminalSessionId,
            assetId = assetId,
            displayName = displayName,
            baseSessionId = baseSessionId,
            terminalChannelId = opened.terminalChannelId,
            engine = engine,
            revision = 0,
        )
        mutableSelectedSessionId.value = terminalSessionId
        NativeTerminalOutputRouter.activate(opened.terminalChannelId)
        val earlyOutput = pendingOutputByChannel.remove(opened.terminalChannelId)
        if (earlyOutput != null) {
            earlyOutput.chunks.forEach(engine::append)
            sessions.value = sessions.value.map { session ->
                if (session.id == terminalSessionId) session.copy(revision = earlyOutput.chunks.size.toLong()) else session
            }
        }
        foregroundSessions.sessionOpened()
        recoveryStore.markLiveSessionsPresent()
        return true
    }

    suspend fun openTelnet(
        asset: ServerAsset,
        credentials: ServerCredentials,
        columns: Int = DEFAULT_COLUMNS,
        rows: Int = DEFAULT_ROWS,
    ): Boolean {
        if (asset.transport != ServerTransportProtocol.telnet.name || credentials.password.isEmpty()) return false
        val sessionId = UUID.randomUUID().toString()
        val channelId = nextTelnetChannelId.getAndDecrement()
        lateinit var connection: TelnetTerminalConnection
        val engine = RemoteTerminalEngine(columns, rows, onInput = { bytes ->
            scope.launch(Dispatchers.IO) { connection.write(bytes) }
        })
        connection = TelnetTerminalConnection(
            host = asset.host,
            port = asset.port,
            username = asset.username,
            password = credentials.password,
            profile = runCatching { NetworkDeviceProfile.valueOf(asset.networkDeviceProfile) }.getOrDefault(NetworkDeviceProfile.auto),
            onData = { bytes ->
                scope.launch {
                    engine.append(bytes)
                    scheduleRenderInvalidation(channelId)
                }
            },
            onClosed = { reason ->
                scope.launch {
                    if (reason != null) engine.append("\r\n[Telnet 连接已断开]\r\n".toByteArray())
                    markDisconnected(channelId)
                    scheduleRenderInvalidation(channelId)
                }
            },
        )
        val connected = withContext(Dispatchers.IO) { connection.connect(columns, rows) }
        if (!connected) return false
        telnetConnections[sessionId] = connection
        sessions.value = sessions.value + ActiveTerminalSession(
            id = sessionId,
            assetId = asset.id,
            displayName = asset.name,
            baseSessionId = channelId,
            terminalChannelId = channelId,
            transport = ServerTransportProtocol.telnet.name,
            engine = engine,
        )
        mutableSelectedSessionId.value = sessionId
        foregroundSessions.sessionOpened()
        recoveryStore.markLiveSessionsPresent()
        return true
    }

    fun select(sessionId: String) {
        if (sessions.value.any { it.id == sessionId }) {
            mutableSelectedSessionId.value = sessionId
        }
    }

    fun resize(sessionId: String, columns: Int, rows: Int) {
        val session = sessions.value.firstOrNull { it.id == sessionId } ?: return
        session.engine.resize(columns, rows)
        sessions.value = sessions.value.map {
            if (it.id == sessionId) it.copy(revision = it.revision + 1) else it
        }
        if (session.transport == ServerTransportProtocol.telnet.name) {
            telnetConnections[sessionId]?.resize(columns, rows)
        } else {
            scope.launch(Dispatchers.IO) {
                handleTerminalCommandResult(
                    session.terminalChannelId,
                    nativeClient.resize(session.terminalChannelId, columns, rows),
                )
            }
        }
    }

    fun sendInput(sessionId: String, bytes: ByteArray) {
        val session = sessions.value.firstOrNull { it.id == sessionId } ?: return
        session.engine.sendInput(bytes)
    }

    fun sendCommand(sessionId: String, command: String) {
        val normalized = command.trim()
        if (normalized.isEmpty()) return
        val session = sessions.value.firstOrNull { it.id == sessionId } ?: return
        session.engine.sendInput((normalized + "\r").toByteArray(Charsets.UTF_8))
        sessions.value = sessions.value.map { current ->
            if (current.id == sessionId) {
                current.copy(commandHistory = (listOf(normalized) + current.commandHistory.filterNot { it == normalized }).take(MAX_COMMAND_HISTORY))
            } else {
                current
            }
        }
    }

    /**
     * Inserts a snippet into the remote line editor without submitting it.
     * Unlike [sendCommand], this deliberately preserves the authored spacing
     * and never appends CR/LF or mutates command history.
     */
    fun insertCommand(sessionId: String, command: String) {
        val payload = terminalInsertedCommandBytes(command) ?: return
        val session = sessions.value.firstOrNull { it.id == sessionId } ?: return
        session.engine.sendInput(payload)
    }

    /** Clears only the local viewport history, then asks the remote line editor to redraw its screen. */
    fun clearTerminal(sessionId: String) {
        val session = sessions.value.firstOrNull { it.id == sessionId } ?: return
        session.engine.emulator.screen.clearTranscript()
        session.engine.sendInput(byteArrayOf(FORM_FEED))
        sessions.value = sessions.value.map {
            if (it.id == sessionId) it.copy(revision = it.revision + 1) else it
        }
    }

    fun close(sessionId: String) {
        val session = sessions.value.firstOrNull { it.id == sessionId } ?: return
        if (session.transport != ServerTransportProtocol.telnet.name) NativeTerminalOutputRouter.retire(session.terminalChannelId)
        pendingOutputByChannel.remove(session.terminalChannelId)
        pendingRenderChannels.remove(session.terminalChannelId)
        val remaining = sessions.value.filterNot { it.id == sessionId }
        sessions.value = remaining
        if (mutableSelectedSessionId.value == sessionId) {
            mutableSelectedSessionId.value = remaining.lastOrNull()?.id
        }
        if (session.transport == ServerTransportProtocol.telnet.name) {
            telnetConnections.remove(sessionId)?.close()
        } else scope.launch(Dispatchers.IO) {
            nativeClient.close(session.terminalChannelId)
            checkedSsh.disconnect(session.baseSessionId)
        }
        if (remaining.isEmpty()) {
            foregroundSessions.sessionsClosed()
            recoveryStore.clearLiveSessions()
        }
    }

    /** Releases every live terminal and its verified SSH base session. */
    fun closeAll() {
        sessionGeneration += 1
        val active = sessions.value
        sessions.value = emptyList()
        mutableSelectedSessionId.value = null
        pendingOutputByChannel.clear()
        pendingRenderChannels.clear()
        renderFlushJob?.cancel()
        renderFlushJob = null
        recoveryStore.clearLiveSessions()
        active.filter { it.transport != ServerTransportProtocol.telnet.name }
            .forEach { session -> NativeTerminalOutputRouter.retire(session.terminalChannelId) }
        telnetConnections.values.forEach(TelnetTerminalConnection::close)
        telnetConnections.clear()
        if (active.isEmpty()) return
        foregroundSessions.sessionsClosed()
        scope.launch(Dispatchers.IO) {
            active.filter { it.transport != ServerTransportProtocol.telnet.name }.forEach { session ->
                nativeClient.close(session.terminalChannelId)
                checkedSsh.disconnect(session.baseSessionId)
            }
        }
    }

    private fun bufferEarlyOutput(output: com.orbitterm.android.core.TerminalOutputChunk) {
        val now = android.os.SystemClock.elapsedRealtime()
        pendingOutputByChannel.entries.removeAll { (_, pending) ->
            now - pending.firstReceivedAtMillis > EARLY_OUTPUT_TTL_MILLIS
        }
        if (output.terminalChannelId !in pendingOutputByChannel) {
            while (pendingOutputByChannel.size >= RuntimeResourceBudget.TERMINAL_EARLY_OUTPUT_MAX_CHANNELS) {
                val oldest = pendingOutputByChannel.entries.iterator()
                if (!oldest.hasNext()) break
                oldest.next()
                oldest.remove()
            }
        }
        val pending = pendingOutputByChannel.getOrPut(output.terminalChannelId) {
            PendingTerminalOutput(firstReceivedAtMillis = now)
        }
        val allowedBytes = (RuntimeResourceBudget.TERMINAL_EARLY_OUTPUT_MAX_BYTES_PER_CHANNEL - pending.byteCount).coerceAtLeast(0)
        if (allowedBytes == 0) return
        val chunk = output.bytes.copyOf(allowedBytes.coerceAtMost(output.bytes.size))
        pending.chunks += chunk
        pending.byteCount += chunk.size
    }

    /**
     * Terminal output can arrive in very small native chunks. The emulator still
     * receives every chunk, while Compose observes at most one revision batch per
     * display frame. This avoids a state update per byte without delaying output.
     */
    private fun scheduleRenderInvalidation(terminalChannelId: Long) {
        if (!pendingRenderChannels.offer(terminalChannelId)) return
        if (renderFlushJob?.isActive == true) return
        renderFlushJob = scope.launch {
            delay(RuntimeResourceBudget.TERMINAL_RENDER_FRAME_MILLIS)
            val dirtyChannels = pendingRenderChannels.drain()
            if (dirtyChannels.isEmpty()) return@launch
            sessions.value = sessions.value.map { session ->
                if (session.terminalChannelId in dirtyChannels) session.copy(revision = session.revision + 1) else session
            }
        }
    }

    private fun handleTerminalCommandResult(
        terminalChannelId: Long,
        result: CheckedTerminalCommandResult,
    ) {
        val failure = result as? CheckedTerminalCommandResult.Failure ?: return
        if (!terminalFailureClosesSession(failure.code)) return
        scope.launch { markDisconnected(terminalChannelId) }
    }

    private fun markDisconnected(terminalChannelId: Long) {
        sessions.value = sessions.value.map { session ->
            if (session.terminalChannelId == terminalChannelId) {
                session.copy(
                    connectionState = TerminalSessionConnectionState.Disconnected,
                    revision = session.revision + 1,
                )
            } else {
                session
            }
        }
    }

    private class PendingTerminalOutput(
        val firstReceivedAtMillis: Long,
        val chunks: MutableList<ByteArray> = mutableListOf(),
        var byteCount: Int = 0,
    )

    private companion object {
        const val DEFAULT_COLUMNS = 100
        const val DEFAULT_ROWS = 32
        const val EARLY_OUTPUT_TTL_MILLIS = 5_000L
        const val MAX_COMMAND_HISTORY = 50
        const val FORM_FEED: Byte = 12
    }
}

internal fun terminalInsertedCommandBytes(command: String): ByteArray? =
    command.takeUnless(String::isBlank)?.toByteArray(Charsets.UTF_8)
