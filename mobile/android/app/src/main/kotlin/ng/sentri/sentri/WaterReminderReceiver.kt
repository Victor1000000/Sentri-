package ng.sentri.sentri

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * v43: the drink-water reminder as a NATIVE self-perpetuating alarm chain.
 *
 * Why this exists: the Dart side (push_service.dart) used to lay a chain of one-shot
 * alarms through flutter_local_notifications, and on several phones (notably Transsion
 * XOS / HiOS power managers) that chain was pruned to its FIRST link - one reminder
 * arrived, then silence. A receiver the system itself wakes, which re-arms the NEXT
 * alarm before returning, cannot be pruned that way: even if the process is killed
 * between alarms, the alarm clock entry lives in the system, and every firing re-seeds
 * the following one.
 *
 * The Dart side hands over (minutes, title, body) through the ng.sentri/water
 * MethodChannel; this class stores them in its own SharedPreferences, shows each
 * reminder through the 'sentri_health' channel, and schedules the next occurrence a
 * whole interval out. Status readback reports the stored pace and whether the system
 * still allows notifications, so the Health tab can keep showing the honest state.
 *
 * WaterBootReceiver re-seeds the chain after a reboot (alarms do not survive one).
 */
class WaterReminderReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_ALARM) return
        val p = prefs(context)
        val minutes = p.getInt(KEY_MINUTES, 0)
        if (minutes <= 0) return
        show(context, p.getString(KEY_TITLE, "") ?: "", p.getString(KEY_BODY, "") ?: "")
        // Re-arm FIRST-CLASS: the next reminder exists even if nothing else happens.
        scheduleNext(context)
    }

    companion object {
        const val CHANNEL_ID = "sentri_health"
        const val ACTION_ALARM = "ng.sentri.sentri.WATER_ALARM"
        private const val REQUEST_CODE = 7301
        private const val KEY_MINUTES = "minutes"
        private const val KEY_TITLE = "title"
        private const val KEY_BODY = "body"
        private const val KEY_NEXT_AT = "nextAt"
        private const val PREFS = "sentri_water"

        internal fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        /// Writes the pace and words, then schedules the FIRST occurrence one interval out.
        ///
        /// Idempotent on purpose: the Health tab re-arms the reminder on every app open,
        /// and a start that blindly rescheduled would push the next reminder a whole
        /// interval out every time - a person who opens the app often would starve the
        /// reminders. So a start whose pace AND words already match a live chain whose
        /// next alarm is still comfortably in the future leaves that chain alone; only
        /// a changed pace, new words, or a dead/expired chain re-seeds it.
        fun start(context: Context, minutes: Int, title: String, body: String) {
            val p = prefs(context)
            val nextAt = p.getLong(KEY_NEXT_AT, 0L)
            val same =
                p.getInt(KEY_MINUTES, 0) == minutes &&
                p.getString(KEY_TITLE, "") == title &&
                p.getString(KEY_BODY, "") == body
            if (same && nextAt > System.currentTimeMillis() + 60_000L) return
            p.edit()
                .putInt(KEY_MINUTES, minutes)
                .putString(KEY_TITLE, title)
                .putString(KEY_BODY, body)
                .apply()
            scheduleNext(context)
        }

        /// Schedules the next alarm one whole interval from now, exactly when the phone
        /// allows it, gently-inexact when it does not, and records the truth in prefs so
        /// the Dart side's status readback stays honest.
        fun scheduleNext(context: Context) {
            val p = prefs(context)
            val minutes = p.getInt(KEY_MINUTES, 0)
            if (minutes <= 0) return
            val at = System.currentTimeMillis() + minutes * 60_000L
            val pi = PendingIntent.getBroadcast(
                context,
                REQUEST_CODE,
                Intent(context, WaterReminderReceiver::class.java).setAction(ACTION_ALARM),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val exactAllowed = if (Build.VERSION.SDK_INT >= 31) am.canScheduleExactAlarms() else true
            try {
                if (exactAllowed) {
                    am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
                } else {
                    am.setWindow(AlarmManager.RTC_WAKEUP, at, 10 * 60_000L, pi)
                }
            } catch (_: SecurityException) {
                try {
                    am.setWindow(AlarmManager.RTC_WAKEUP, at, 10 * 60_000L, pi)
                } catch (_: Exception) {
                }
            }
            p.edit().putLong(KEY_NEXT_AT, at).putInt(KEY_MINUTES, minutes).apply()
        }

        /// Cancels the pending alarm and clears the stored pace.
        fun stop(context: Context) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pi = PendingIntent.getBroadcast(
                context,
                REQUEST_CODE,
                Intent(context, WaterReminderReceiver::class.java).setAction(ACTION_ALARM),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            try {
                am.cancel(pi)
            } catch (_: Exception) {
            }
            prefs(context).edit().putInt(KEY_MINUTES, 0).putLong(KEY_NEXT_AT, 0L).apply()
        }

        /// (pace, nextAt, notificationsAllowed) for the Dart status readback.
        fun status(context: Context): Map<String, Any> {
            val p = prefs(context)
            val nextAt = p.getLong(KEY_NEXT_AT, 0L)
            val minutes = p.getInt(KEY_MINUTES, 0)
            val live = minutes > 0 && nextAt > System.currentTimeMillis() - 60_000L
            return mapOf(
                "minutes" to (if (live) minutes else 0),
                "nextAt" to (if (live) nextAt else 0L),
                "notifications" to NotificationManagerCompat.from(context).areNotificationsEnabled()
            )
        }

        private fun show(context: Context, title: String, body: String) {
            val nm = NotificationManagerCompat.from(context)
            nm.createNotificationChannel(
                NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_HIGH)
                    .setName("Health")
                    .setDescription("Drink-water reminders and gentle heart-rate notes from your own Health tab.")
                    .build()
            )
            if (!nm.areNotificationsEnabled()) return
            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_sentri)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setAutoCancel(true)
                .build()
            try {
                nm.notify(7201, n)
            } catch (_: SecurityException) {
                // A refused notification permission must never stop the chain.
            }
        }
    }
}

/** Re-seeds the water chain after a reboot or an app update; alarms do not survive either. */
class WaterBootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val p = WaterReminderReceiver.prefs(context)
        if (p.getInt("minutes", 0) > 0) {
            WaterReminderReceiver.scheduleNext(context)
        }
    }
}
