package ng.sentri.sentri

import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * The screen. It attaches to the shared engine from [SentriEngine], so an alert that was started by a
 * gesture while the phone slept is already running when this opens. Shows over the lock screen so the
 * cancel-PIN screen is visible when an alert starts from a locked phone.
 */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
    }

    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine = SentriEngine.get(context)

    /** The engine outlives the screen: it keeps the alert and the location share running. */
    override fun shouldDestroyEngineWithHost(): Boolean = false
}
