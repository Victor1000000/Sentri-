package ng.sentri.sentri

import android.app.PendingIntent
import android.content.Intent
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.os.Build

/**
 * Quick Settings tile ("Sentri alert"). Pulling down the shade works from the lock screen, so this
 * is another way to start an alert without opening the app. It deliberately does NOT ask the user
 * to unlock first: the alert screen shows over the lock screen.
 */
class SentriTileService : TileService() {
    override fun onStartListening() {
        qsTile?.apply {
            state = if (Prefs.load(this@SentriTileService).enabled) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            updateTile()
        }
    }

    override fun onClick() {
        if (!TriggerDispatcher.begin(this, "widget")) return
        val intent = TriggerDispatcher.intentFor(this, "widget")
        if (Build.VERSION.SDK_INT >= 34) {
            // Android 14 replaced the Intent overload with a PendingIntent one.
            startActivityAndCollapse(
                PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
