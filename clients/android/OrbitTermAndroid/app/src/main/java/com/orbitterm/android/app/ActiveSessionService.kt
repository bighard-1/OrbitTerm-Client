package com.orbitterm.android.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import com.orbitterm.android.MainActivity
import com.orbitterm.android.feature.terminal.TerminalSessionController
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * Keeps only already-verified terminal channels alive while OrbitTerm is not
 * visible. It is deliberately non-sticky: a process restart cannot restore
 * native handles and must never pretend that an SSH session survived.
 */
@AndroidEntryPoint
class ActiveSessionService : Service() {
    @Inject lateinit var terminalSessions: TerminalSessionController

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var sessionObserver: Job? = null
    private var backgroundTimeout: Job? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        sessionObserver = serviceScope.launch {
            terminalSessions.activeSessions.collectLatest { active ->
                if (active.isEmpty()) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                } else {
                    publish(active.size)
                }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_DISCONNECT_ALL -> terminalSessions.closeAll()
            ACTION_APP_BACKGROUNDED -> scheduleBackgroundTimeout()
            ACTION_APP_FOREGROUNDED -> backgroundTimeout?.cancel()
            ACTION_START, null -> publish(terminalSessions.activeSessions.value.size)
        }
        // Native handles cannot survive process death, so never request a
        // misleading automatic restart with stale UI state.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        backgroundTimeout?.cancel()
        sessionObserver?.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun scheduleBackgroundTimeout() {
        backgroundTimeout?.cancel()
        backgroundTimeout = serviceScope.launch {
            delay(BACKGROUND_SESSION_TIMEOUT_MILLIS)
            terminalSessions.closeAll()
        }
    }

    private fun publish(sessionCount: Int) {
        val notification = notification(sessionCount)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun notification(sessionCount: Int): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val disconnect = PendingIntent.getService(
            this,
            1,
            Intent(this, ActiveSessionService::class.java).setAction(ACTION_DISCONNECT_ALL),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle("OrbitTerm 正在保持会话")
            .setContentText("$sessionCount 个已验证 SSH 会话保持连接")
            .setContentIntent(openApp)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "全部断开", disconnect).build())
            .build()
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "活动 SSH 会话",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "OrbitTerm 在后台保持已验证的 SSH 会话时显示。"
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    companion object {
        const val ACTION_START = "com.orbitterm.android.session.START"
        const val ACTION_DISCONNECT_ALL = "com.orbitterm.android.session.DISCONNECT_ALL"
        const val ACTION_APP_BACKGROUNDED = "com.orbitterm.android.session.APP_BACKGROUNDED"
        const val ACTION_APP_FOREGROUNDED = "com.orbitterm.android.session.APP_FOREGROUNDED"
        private const val CHANNEL_ID = "active_ssh_sessions"
        private const val NOTIFICATION_ID = 4102
        private const val BACKGROUND_SESSION_TIMEOUT_MILLIS = 30 * 60 * 1_000L
    }
}
