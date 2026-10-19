package ng.sentri.sentri

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.SensorManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * The always-on part. Keeps the process alive and listens for shake / screen-toggle gestures and
 * hosts the floating button. (Volume gestures are handled by the accessibility service.)
 *
 * The notification is deliberately bland ("Sentri protection is on"), hidden on the lock screen,
 * silent, and never mentions an alert.
 */
class ProtectionService : Service() {
    private var shake: ShakeDetector? = null
    private var power: ScreenToggleDetector? = null
    private var floating: FloatingButton? = null
    private var wake: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startAsForeground()
        applyPrefs()
        // If the system kills the service, restart it with the last intent.
        return START_STICKY
    }

    private fun startAsForeground() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, getString(R.string.protection_channel), NotificationManager.IMPORTANCE_LOW).apply {
                lockscreenVisibility = Notification.VISIBILITY_SECRET
                setShowBadge(false)
            },
        )
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        val n = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_sentri)
            .setContentTitle(getString(R.string.protection_on))
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_SECRET)
            .setContentIntent(open)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(NOTIF_ID, n)
            }
        } catch (e: Exception) {
            Log.e("Sentri", "could not start foreground", e)
            stopSelf()
        }
    }

    private fun applyPrefs() {
        val p = Prefs.load(this)
        if (!p.enabled) {
            stopSelf()
            return
        }
        val sm = getSystemService(Context.SENSOR_SERVICE) as SensorManager

        // Start the Flutter engine now so a gesture on a sleeping phone can start the alert at once.
        SentriEngine.get(this)

        // Without this, many phones stop delivering motion events once the screen has been off for a while.
        if (p.shake || p.power) holdWake() else releaseWake()

        shake?.unregister(sm); shake = null
        if (p.shake) shake = ShakeDetector(p.shakeSensitivity) { TriggerDispatcher.fire(this, "shake") }.also { it.register(sm) }

        power?.unregister(this); power = null
        if (p.power) power = ScreenToggleDetector { TriggerDispatcher.fire(this, "power") }.also { it.register(this) }

        if (p.floating) {
            if (floating == null) floating = FloatingButton(this)
            floating?.show()
        } else {
            floating?.hide()
        }
    }

    private fun holdWake() {
        if (wake?.isHeld == true) return
        wake = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "sentri:protection")
            .apply { setReferenceCounted(false); acquire() }
    }

    private fun releaseWake() {
        wake?.takeIf { it.isHeld }?.release()
        wake = null
    }

    override fun onDestroy() {
        releaseWake()
        val sm = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        shake?.unregister(sm)
        power?.unregister(this)
        floating?.hide()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "protection"
        private const val NOTIF_ID = 1001

        fun start(ctx: Context) {
            ctx.startForegroundService(Intent(ctx, ProtectionService::class.java))
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, ProtectionService::class.java))
        }
    }
}
