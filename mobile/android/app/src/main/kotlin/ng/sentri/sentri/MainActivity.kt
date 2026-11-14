package ng.sentri.sentri

import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The screen. It attaches to the shared engine from [SentriEngine], so an alert that was started by a
 * gesture while the phone slept is already running when this opens. Shows over the lock screen so the
 * cancel-PIN screen is visible when an alert starts from a locked phone.
 *
 * It extends [FlutterFragmentActivity] (not the plain FlutterActivity) on purpose: the Health tab's
 * permission requests go through Android's registerForActivityResult, which only exists on
 * ComponentActivity - and FragmentActivity is that. Everything else behaves identically.
 *
 * v43: hosts the ng.sentri/water MethodChannel - the Dart side's way into the NATIVE
 * drink-water alarm chain in [WaterReminderReceiver]. The plugin-based chain of pre-laid
 * one-shot notifications was being pruned to its first link by some phones' power
 * managers (Transsion XOS / HiOS in particular): one reminder arrived, then silence.
 * A receiver the system itself wakes, which re-arms the next alarm before returning,
 * cannot be pruned that way. The channel is registered in [configureFlutterEngine],
 * which runs for the shared engine on every screen open; setting the handler again
 * simply replaces the previous one, so re-entry is safe.
 */
class MainActivity : FlutterFragmentActivity() {
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ng.sentri/water")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "schedule" -> {
                        val minutes = call.argument<Int>("minutes") ?: 0
                        val title = call.argument<String>("title") ?: ""
                        val body = call.argument<String>("body") ?: ""
                        if (minutes <= 0) {
                            result.error("bad_args", "minutes must be positive", null)
                        } else {
                            WaterReminderReceiver.start(applicationContext, minutes, title, body)
                            result.success(null)
                        }
                    }
                    "cancel" -> {
                        WaterReminderReceiver.stop(applicationContext)
                        result.success(null)
                    }
                    "status" -> result.success(WaterReminderReceiver.status(applicationContext))
                    else -> result.notImplemented()
                }
            }
    }

    /** The engine outlives the screen: it keeps the alert and the location share running. */
    override fun shouldDestroyEngineWithHost(): Boolean = false
}
