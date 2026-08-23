package com.orbitterm.android

import android.app.Application
import com.orbitterm.android.core.NativeTerminalOutputRouter
import com.orbitterm.android.core.NativeSftpProgressRouter
import com.orbitterm.android.core.OrbitCoreBridge
import dagger.hilt.android.HiltAndroidApp

@HiltAndroidApp
class OrbitTermAndroidApp : Application() {
    override fun onCreate() {
        super.onCreate()
        OrbitCoreBridge.installTerminalOutputCallback(NativeTerminalOutputRouter)
        OrbitCoreBridge.installSftpProgressCallback(NativeSftpProgressRouter)
    }
}
