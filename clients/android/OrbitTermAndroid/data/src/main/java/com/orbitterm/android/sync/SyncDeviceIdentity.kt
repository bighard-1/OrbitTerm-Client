package com.orbitterm.android.sync

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

/** Stable non-secret device identifier required by the server's mutation API. */
@Singleton
class SyncDeviceIdentity @Inject constructor(@ApplicationContext context: Context) {
    private val preferences = context.getSharedPreferences("orbitterm_sync_identity", Context.MODE_PRIVATE)

    val value: String = preferences.getString(KEY, null) ?: UUID.randomUUID().toString().also { generated ->
        check(preferences.edit().putString(KEY, generated).commit()) { "sync device identity write failed" }
    }

    private companion object { const val KEY = "device_id_v1" }
}
