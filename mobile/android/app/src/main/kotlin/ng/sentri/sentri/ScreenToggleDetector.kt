package ng.sentri.sentri

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter

/**
 * BEST EFFORT "power button presses" (the count is the person's choice, 3..6).
 *
 * Android does not let ordinary apps see the power button. What an app CAN see is the screen
 * turning off and on, which pressing the power button repeatedly causes. That many screen toggles
 * (the chosen count) within [WINDOW_MS] is treated as the gesture. It is a heuristic: some phones (and Doze) delay
 * or swallow these broadcasts, and an unlock/lock sequence can look the same, so it is off by
 * default and described to the user as "may not work on every phone".
 *
 * v39: four presses instead of three - people were setting off the alert by accident (a pocket,
 * an unlock-and-lock, a nervous triple-press). One more press costs nothing in an emergency and
 * filters out the accidental sequences; the window widens a second to match.
 *
 * v44: the count is no longer fixed. The person picks their own number (3..6, default 4) in the
 * trigger settings, so the alert goes off on exactly the number of presses they chose - which
 * keeps them conscious of when it fires.
 */
class ScreenToggleDetector(
    private val onTrigger: () -> Unit,
    /** v44: the person's chosen press count, 3..6. */
    presses: Int = 4,
) : BroadcastReceiver() {
    private val times = ArrayDeque<Long>()
    private var lastFiredAt = 0L
    private val required = presses.coerceIn(3, 6)

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
        if (times.size >= required) {
            times.clear()
            lastFiredAt = now
            onTrigger()
        }
    }

    companion object {
        private const val WINDOW_MS = 4_000L
        private const val COOLDOWN_MS = 8_000L
    }
}
