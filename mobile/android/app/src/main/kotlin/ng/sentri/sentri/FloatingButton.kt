package ng.sentri.sentri

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.WindowManager
import android.widget.TextView
import kotlin.math.abs

/**
 * A small draggable button that floats over other apps. A deliberate HOLD of one second fires the
 * alert, so a stray tap or a drag does nothing. Needs the "display over other apps" permission.
 */
class FloatingButton(private val ctx: Context) {
    private val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val handler = Handler(Looper.getMainLooper())
    private var view: TextView? = null

    @SuppressLint("ClickableViewAccessibility")
    fun show() {
        if (view != null || !Settings.canDrawOverlays(ctx)) return
        val size = (ctx.resources.displayMetrics.density * 52).toInt()
        val tv = TextView(ctx).apply {
            text = "SOS"
            setTextColor(Color.WHITE)
            textSize = 12f
            gravity = Gravity.CENTER
            alpha = 0.55f // visible but unobtrusive
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor("#C62828"))
            }
        }
        val lp = WindowManager.LayoutParams(
            size, size,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = 0
            y = (ctx.resources.displayMetrics.heightPixels * 0.35).toInt()
        }

        var startX = 0f
        var startY = 0f
        var origX = 0
        var origY = 0
        var dragged = false
        val fire = Runnable {
            if (!dragged) TriggerDispatcher.fire(ctx, "floating")
        }

        tv.setOnTouchListener { v, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> {
                    startX = e.rawX; startY = e.rawY; origX = lp.x; origY = lp.y; dragged = false
                    v.alpha = 1f
                    handler.postDelayed(fire, HOLD_MS)
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - startX
                    val dy = e.rawY - startY
                    if (abs(dx) > DRAG_SLOP || abs(dy) > DRAG_SLOP) {
                        dragged = true
                        handler.removeCallbacks(fire)
                        lp.x = origX + dx.toInt()
                        lp.y = origY + dy.toInt()
                        wm.updateViewLayout(v, lp)
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    handler.removeCallbacks(fire)
                    v.alpha = 0.55f
                }
            }
            true
        }
        wm.addView(tv, lp)
        view = tv
    }

    fun hide() {
        view?.let {
            try {
                wm.removeView(it)
            } catch (_: IllegalArgumentException) {
            }
        }
        view = null
    }

    companion object {
        private const val HOLD_MS = 1_000L
        private const val DRAG_SLOP = 12f
    }
}
