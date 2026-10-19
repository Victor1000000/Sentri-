package ng.sentri.sentri

import android.content.Context

/** Trigger settings shared between the Flutter app and the always-on native services. */
object Prefs {
    private const val FILE = "sentri_native"

    data class Triggers(
        val enabled: Boolean,
        val shake: Boolean,
        val volume: Boolean,
        val power: Boolean,
        val floating: Boolean,
        val shakeSensitivity: Double,
    )

    fun save(ctx: Context, t: Triggers) {
        ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit()
            .putBoolean("enabled", t.enabled)
            .putBoolean("shake", t.shake)
            .putBoolean("volume", t.volume)
            .putBoolean("power", t.power)
            .putBoolean("floating", t.floating)
            .putFloat("sens", t.shakeSensitivity.toFloat())
            .apply()
    }

    fun load(ctx: Context): Triggers {
        val p = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        return Triggers(
            enabled = p.getBoolean("enabled", false),
            shake = p.getBoolean("shake", true),
            volume = p.getBoolean("volume", true),
            power = p.getBoolean("power", false),
            floating = p.getBoolean("floating", true),
            shakeSensitivity = p.getFloat("sens", 1.0f).toDouble(),
        )
    }
}
