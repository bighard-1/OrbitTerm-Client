package com.orbitterm.android.app

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import com.orbitterm.android.core.SessionForegroundController

/** Starts the service only after a verified terminal channel is active. */
@Singleton
class SessionForegroundServiceController @Inject constructor(
    @param:ApplicationContext private val context: Context,
) : SessionForegroundController {
    override fun sessionOpened() = dispatch(ActiveSessionService.ACTION_START)

    override fun sessionsClosed() {
        context.stopService(Intent(context, ActiveSessionService::class.java))
    }

    fun appBackgrounded() = dispatch(ActiveSessionService.ACTION_APP_BACKGROUNDED)

    fun appForegrounded() = dispatch(ActiveSessionService.ACTION_APP_FOREGROUNDED)

    private fun dispatch(action: String) {
        val intent = Intent(context, ActiveSessionService::class.java).setAction(action)
        if (action == ActiveSessionService.ACTION_START || action == ActiveSessionService.ACTION_APP_BACKGROUNDED) {
            ContextCompat.startForegroundService(context, intent)
        } else {
            context.startService(intent)
        }
    }
}
