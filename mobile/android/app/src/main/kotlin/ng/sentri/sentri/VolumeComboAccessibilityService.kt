package ng.sentri.sentri

import android.accessibilityservice.AccessibilityService
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent

/**
 * Volume-button gesture: Up, Down, Up, Down (alternating, four presses) within 2.5 seconds.
 *
 * An accessibility service is the only supported way for a normal app to see hardware keys while
 * the screen is off. It never reads screen content (see accessibility_service_config.xml: no
 * window or content events) and it never consumes the key, so volume keeps working normally.
 *
 * The alternating pattern is deliberate: holding both volume keys for 3 seconds is Android's own
 * accessibility shortcut, so a simple "both keys" gesture would collide with it.
 */
class VolumeComboAccessibilityService : AccessibilityService() {
    private val presses = ArrayDeque<Pair<Int, Long>>()
    private var lastFiredAt = 0L

    override fun onKeyEvent(event: KeyEvent): Boolean {
        if (event.action != KeyEvent.ACTION_DOWN || event.repeatCount != 0) return false
        val code = event.keyCode
        if (code != KeyEvent.KEYCODE_VOLUME_UP && code != KeyEvent.KEYCODE_VOLUME_DOWN) return false
        if (!Prefs.load(this).let { it.enabled && it.volume }) return false

        val now = System.currentTimeMillis()
        if (now - lastFiredAt < COOLDOWN_MS) return false
        // Same key twice in a row breaks the alternating pattern.
        if (presses.isNotEmpty() && presses.last().first == code) presses.clear()
        presses.addLast(code to now)
        while (presses.isNotEmpty() && now - presses.first().second > WINDOW_MS) presses.removeFirst()

        if (presses.size >= REQUIRED_PRESSES) {
            presses.clear()
            lastFiredAt = now
            TriggerDispatcher.fire(this, "volume")
        }
        return false // never swallow the key
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit
    override fun onInterrupt() = Unit

    companion object {
        private const val REQUIRED_PRESSES = 4
        private const val WINDOW_MS = 2_500L
        private const val COOLDOWN_MS = 8_000L
    }
}
