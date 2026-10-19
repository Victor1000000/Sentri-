package ng.sentri.sentri

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * One place that turns "a trigger fired" into "the alert is running, and the screen is shown if it can be".
 *
 * The foreground service, accessibility service, overlay button and quick-settings tile all end
 * here. Starting an activity from the background is normally blocked on Android 10+, but it is
 * allowed for apps holding the "display over other apps" permission, which Sentri asks for.
 * The activity is set to show over the lock screen.
 */
object TriggerDispatcher {
    const val ACTION_TRIGGER = "ng.sentri.sentri.TRIGGER"
    const val EXTRA_TYPE = "type"
    private const val DEBOUNCE_MS = 8_000L

    private var lastFiredAt = 0L

    /** False if a trigger fired a moment ago (e.g. shake and volume together): don't relaunch the screen. */
    @Synchronized
    fun claim(): Boolean {
        val now = System.currentTimeMillis()
        if (now - lastFiredAt < DEBOUNCE_MS) return false
        lastFiredAt = now
        return true
    }

    /** Brings the app to the front (over the lock screen). It only shows the alert; it does not start it. */
    fun intentFor(context: Context, type: String): Intent =
        Intent(context, MainActivity::class.java).apply {
            action = ACTION_TRIGGER
            putExtra(EXTRA_TYPE, type)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
        }

    /**
     * Starts the alert right now, with no screen: the always-on engine runs the alert in Dart (location,
     * server call, tracking) while the phone is still asleep. Returns false if one just fired.
     */
    fun begin(context: Context, type: String): Boolean {
        if (!claim()) return false
        Log.i("Sentri", "trigger fired: $type")
        SentriEngine.deliver(context, type)
        return true
    }

    /** Starts the alert, then tries to show the cancel-PIN screen. */
    fun fire(context: Context, type: String) {
        if (!begin(context, type)) return
        showScreen(context, type)
    }

    /**
     * The activity start is the normal way to wake the screen. A full-screen notification is the backup
     * for phones that block background activity starts. Neither is needed for the alert to go out.
     */
    fun showScreen(context: Context, type: String) {
        val intent = intentFor(context, type)
        try {
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.w("Sentri", "could not open the alert screen", e)
        }
        try {
            val nm = context.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel(ALERT_CHANNEL, context.getString(R.string.alert_channel), NotificationManager.IMPORTANCE_HIGH).apply {
                    lockscreenVisibility = Notification.VISIBILITY_SECRET
                    setShowBadge(false)
                    setSound(null, null)
                },
            )
            val pi = PendingIntent.getActivity(context, 1, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val n = Notification.Builder(context, ALERT_CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_sentri)
                .setContentTitle(context.getString(R.string.alert_open))
                .setCategory(Notification.CATEGORY_CALL)
                .setVisibility(Notification.VISIBILITY_SECRET)
                .setFullScreenIntent(pi, true)
                .setContentIntent(pi)
                .setAutoCancel(true)
                .setTimeoutAfter(20_000)
                .build()
            nm.notify(ALERT_NOTIF_ID, n)
        } catch (e: Exception) {
            Log.w("Sentri", "could not post the alert notification", e)
        }
    }

    private const val ALERT_CHANNEL = "alert_screen"
    private const val ALERT_NOTIF_ID = 1002
}
