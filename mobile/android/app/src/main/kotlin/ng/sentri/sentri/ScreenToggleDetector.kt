package ng.sentri.sentri

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter

/**
 * BEST EFFORT "power button x3".
 *
 * Android does not let ordinary apps see the power button. What an app CAN see is the screen
 * turning off and on, which pressing the power button repeatedly causes. Three screen toggles
 * within [WINDOW_MS] is treated as the gesture. It is a heuristic: some phones (and Doze) delay
 * or swallow these broadcasts, and an unlock/lock sequence can look the same, so it is off by
 * default and described to the user as "may not work on every phone".
 */
class ScreenToggleDetector(private val onTrigger: () -> Unit) : BroadcastReceiver() {
    private val times = ArrayDeque<Long>()
    private var lastFiredAt = 0L

    fun register(ctx: Context) {
        // SCREEN_ON / SCREEN_OFF cannot be declared in the manifest; they need a runtime receiver.
        ctx.registerReceiver(this, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
        })
    }

    fun unregister(ctx: Context) {
        try {
            ctx.unregisterReceiver(this)
        } catch (_: IllegalArgumentException) {
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        val now = System.currentTimeMillis()
        if (now - lastFiredAt < COOLDOWN_MS) return
        times.addLast(now)
        while (times.isNotEmpty() && now - times.first() > WINDOW_MS) times.removeFirst()
        if (times.size >= REQUIRED_TOGGLES) {
            times.clear()
            lastFiredAt = now
            onTrigger()
        }
    }

    companion object {
        private const val REQUIRED_TOGGLES = 3
        private const val WINDOW_MS = 3_000L
        private const val COOLDOWN_MS = 8_000L
    }
}
