package ng.sentri.sentri

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * The one Flutter engine for the whole app, created by whoever needs it first.
 *
 * Why: a gesture on a sleeping phone has to start the alert at once. The always-on service creates
 * this engine ahead of time, so Dart (and the alert logic in it) is already running with no screen.
 * When a trigger fires, native code tells Dart straight away; the alert starts on the server while the
 * activity is still waking up. MainActivity then attaches to this same engine, so the cancel-PIN screen
 * shows the alert that is already running instead of starting a second one.
 */
object SentriEngine {
    private const val CACHE_KEY = "sentri_main"
    private const val CHANNEL = "ng.sentri/native"
    private val main = Handler(Looper.getMainLooper())

    private var channel: MethodChannel? = null

    /** True once Dart has registered its handlers (it calls takePendingTrigger during start-up). */
    @Volatile private var dartReady = false

    /** A trigger that arrived before Dart was ready; Dart collects it with takePendingTrigger. */
    @Volatile private var pending: String? = null

    /** Must run on the main thread. Safe to call many times. */
    fun get(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(CACHE_KEY)?.let { return it }
        val app = context.applicationContext
        val engine = FlutterEngine(app) // also registers the Flutter plugins
        dartReady = false
        install(app, engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(CACHE_KEY, engine)
        return engine
    }

    /** Hands a trigger to Dart: now if it is running, otherwise when it asks. Works with no activity. */
    fun deliver(context: Context, type: String) {
        main.post {
            val engine = get(context)
            val ch = channel
            if (dartReady && ch != null && engine.dartExecutor.isExecutingDart) {
                ch.invokeMethod("onTrigger", type)
            } else {
                pending = type
            }
        }
    }

    private fun install(app: Context, engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "takePendingTrigger" -> {
                    dartReady = true
                    val p = pending
                    pending = null
                    result.success(p)
                }
                "startProtection" -> {
                    Prefs.save(
                        app,
                        Prefs.Triggers(
                            enabled = true,
                            shake = call.argument<Boolean>("shake") ?: true,
                            volume = call.argument<Boolean>("volume") ?: true,
                            power = call.argument<Boolean>("power") ?: false,
                            floating = call.argument<Boolean>("floating") ?: true,
                            shakeSensitivity = call.argument<Double>("shakeSensitivity") ?: 1.0,
                        ),
                    )
                    ProtectionService.start(app)
                    result.success(null)
                }
                "stopProtection" -> {
                    Prefs.save(app, Prefs.load(app).copy(enabled = false))
                    ProtectionService.stop(app)
                    result.success(null)
                }
                "permissions" -> result.success(
                    mapOf(
                        "overlay" to Settings.canDrawOverlays(app),
                        "accessibility" to accessibilityEnabled(app),
                        "battery" to (app.getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(app.packageName) ?: false),
                        "backgroundLocation" to (app.checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED),
                    ),
                )
                "openSettings" -> {
                    openSettings(app, call.arguments as? String ?: "app")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun accessibilityEnabled(ctx: Context): Boolean {
        val enabled = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        val cls = VolumeComboAccessibilityService::class.java.name
        val full = ComponentName(ctx.packageName, cls).flattenToString()
        val short = ComponentName(ctx.packageName, cls).flattenToShortString()
        return enabled.split(':').any { it.equals(full, true) || it.equals(short, true) }
    }

    private fun openSettings(ctx: Context, which: String) {
        val i = when (which) {
            "overlay" -> Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${ctx.packageName}"))
            "accessibility" -> Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            "battery" -> Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            else -> Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${ctx.packageName}"))
        }
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(i)
    }
}
