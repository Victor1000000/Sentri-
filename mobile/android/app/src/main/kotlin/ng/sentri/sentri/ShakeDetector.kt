package ng.sentri.sentri

import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import kotlin.math.sqrt

/**
 * Detects a deliberate shake: [requiredShakes] hard accelerations (each above the threshold, at
 * least [MIN_GAP_MS] apart) within [WINDOW_MS]. Runs inside the foreground service, so it works
 * with the screen off. [sensitivity] 0.5..1.5 lowers or raises the threshold.
 */
class ShakeDetector(
    private val sensitivity: Double,
    private val onShake: () -> Unit,
) : SensorEventListener {

    private val hits = ArrayDeque<Long>()
    private var lastFiredAt = 0L

    // 1.0 -> 2.7 g. Higher sensitivity needs less force.
    private val thresholdG: Double get() = 2.7 / sensitivity.coerceIn(0.5, 1.5)

    fun register(sm: SensorManager) {
        val accel = sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) ?: return
        sm.registerListener(this, accel, SensorManager.SENSOR_DELAY_UI)
    }

    fun unregister(sm: SensorManager) = sm.unregisterListener(this)

    override fun onSensorChanged(e: SensorEvent) {
        val g = sqrt((e.values[0] * e.values[0] + e.values[1] * e.values[1] + e.values[2] * e.values[2]).toDouble()) /
            SensorManager.GRAVITY_EARTH
        if (g < thresholdG) return
        val now = System.currentTimeMillis()
        if (now - lastFiredAt < COOLDOWN_MS) return
        if (hits.isNotEmpty() && now - hits.last() < MIN_GAP_MS) return
        hits.addLast(now)
        while (hits.isNotEmpty() && now - hits.first() > WINDOW_MS) hits.removeFirst()
        if (hits.size >= REQUIRED_SHAKES) {
            hits.clear()
            lastFiredAt = now
            onShake()
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    companion object {
        private const val REQUIRED_SHAKES = 3
        private const val WINDOW_MS = 1_500L
        private const val MIN_GAP_MS = 150L
        private const val COOLDOWN_MS = 5_000L
    }
}
