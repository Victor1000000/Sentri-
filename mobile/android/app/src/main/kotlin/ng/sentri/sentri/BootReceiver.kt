package ng.sentri.sentri

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restarts protection after a reboot or an app update, if the user had it on. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            if (Prefs.load(context).enabled) ProtectionService.start(context)
        }
    }
}
