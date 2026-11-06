package tech.zseven.rish.gpui

import android.app.Application

/** Native task callbacks can arrive before an Activity or renderer exists. */
class RishGpuiApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        RishGpuiBridge.initialize(this)
    }
}
