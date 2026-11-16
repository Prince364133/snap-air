package live.snapy.app

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView

/**
 * One small capsule window directly under the camera cut-out (docs/ANDROID_NEXT_PLAN.md §3, §5, §6):
 * captions, the reel-lock line, the red "recording notes" line and the 80% breathing bubble.
 * 28 dp high, 11.5 sp text. Drawn as TYPE_ACCESSIBILITY_OVERLAY from the Real Count service
 * when it runs (no extra permission), else TYPE_APPLICATION_OVERLAY with "Display over other
 * apps", else not at all. Colours come from the theme tokens below (no brand colours) or the
 * caller (app palette from AppPaletteExtractor).
 */
class CameraCapsule(private val name: String) {
    private val main = Handler(Looper.getMainLooper())
    private var view: LinearLayout? = null
    private var text: TextView? = null
    private var wave: WaveDot? = null
    private var wm: WindowManager? = null
    private val hide = Runnable { dismiss() }
    var onTap: (() -> Unit)? = null

    val isShown get() = view != null

    private fun host(ctx: Context): Pair<Context, Int>? {
        val svc = SnapyAccessibilityService.instance
        if (svc != null) return svc to WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY
        if (Settings.canDrawOverlays(ctx)) return ctx.applicationContext to WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        return null
    }

    /** [ms] <= 0 keeps it until [dismiss]. [color] = the dot/accent (ARGB). */
    fun show(ctx: Context, line: String, color: Int = ACCENT, ms: Long = 0, touchable: Boolean = false) = main.post {
        val clean = line.trim()
        if (clean.isEmpty()) return@post
        main.removeCallbacks(hide)
        if (view == null && !create(ctx, touchable)) return@post
        if (touchable != isTouchable) setTouchable(touchable)        // e.g. the lock line ("tap: 5 more") over a deflector bubble
        text?.text = clean
        wave?.color = color
        if (ms > 0) main.postDelayed(hide, ms)
    }

    /** Fade out after [ms]. */
    fun hideIn(ms: Long) = main.post { main.removeCallbacks(hide); main.postDelayed(hide, ms) }

    /** Mic level 0..1: the soundwave ring around the dot. */
    fun level(l: Float) = main.post { wave?.level = l.coerceIn(0f, 1f) }

    private var isTouchable = false
    private var lp: WindowManager.LayoutParams? = null

    private fun flagsFor(touchable: Boolean) = WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
        (if (touchable) WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL else WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE)

    private fun setTouchable(touchable: Boolean) {
        val v = view ?: return
        val p = lp ?: return
        p.flags = flagsFor(touchable)
        if (touchable) v.setOnClickListener { onTap?.invoke() } else { v.setOnClickListener(null); v.isClickable = false }
        try { wm?.updateViewLayout(v, p); isTouchable = touchable } catch (_: Exception) { }
    }

    private fun create(ctx: Context, touchable: Boolean): Boolean {
        val (c, type) = host(ctx) ?: return false
        val d = c.resources.displayMetrics
        fun dp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, d).toInt()
        val w = c.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val tv = TextView(c).apply {
            setTextColor(TEXT)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.START                         // live words: keep the newest
            maxWidth = (d.widthPixels * 0.8).toInt()
            setPadding(dp(6f), 0, dp(12f), 0)
        }
        val dot = WaveDot(c).apply { layoutParams = LinearLayout.LayoutParams(dp(18f), dp(18f)).apply { leftMargin = dp(6f) } }
        val root = LinearLayout(c).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(28f)
            background = GradientDrawable().apply { cornerRadius = dp(14f).toFloat(); setColor(SURFACE); setStroke(dp(1f), OUTLINE) }
            addView(dot); addView(tv)
            contentDescription = name
            if (touchable) setOnClickListener { onTap?.invoke() }
        }
        val flags = flagsFor(touchable)
        val params = WindowManager.LayoutParams(WindowManager.LayoutParams.WRAP_CONTENT, dp(28f), type, flags, PixelFormat.TRANSLUCENT).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            y = belowCamera(w, d.density) + dp(4f)
            if (Build.VERSION.SDK_INT >= 28) layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        return try {
            w.addView(root, params)
            root.alpha = 0f; root.animate().alpha(1f).setDuration(160).start()
            view = root; text = tv; wave = dot; wm = w; lp = params; isTouchable = touchable
            true
        } catch (_: Exception) { false }
    }

    fun dismiss() = main.post {
        val v = view ?: return@post
        val w = wm
        view = null; text = null; wave?.stop(); wave = null; lp = null; isTouchable = false
        v.animate().alpha(0f).setDuration(200).withEndAction { try { w?.removeView(v) } catch (_: Exception) { } }.start()
    }

    /** A small dot with a ring that breathes with the mic level (the "soundwave halo"). */
    class WaveDot(ctx: Context) : View(ctx) {
        private val p = Paint(Paint.ANTI_ALIAS_FLAG)
        var color: Int = ACCENT; set(v) { field = v; invalidate() }
        var level = 0f; set(v) { field = v; invalidate() }
        private var phase = 0f
        private val anim = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 1400; repeatCount = ValueAnimator.INFINITE
            addUpdateListener { phase = it.animatedValue as Float; invalidate() }
            start()
        }
        fun stop() = anim.cancel()
        override fun onDetachedFromWindow() { anim.cancel(); super.onDetachedFromWindow() }
        override fun onDraw(c: Canvas) {
            val cx = width / 2f; val cy = height / 2f; val r = minOf(cx, cy)
            p.style = Paint.Style.FILL; p.color = color
            c.drawCircle(cx, cy, r * 0.32f, p)
            p.style = Paint.Style.STROKE; p.strokeWidth = r * 0.14f
            val ring = r * (0.5f + 0.45f * maxOf(level, phase * 0.35f))
            p.alpha = (255 * (1f - phase * 0.6f)).toInt().coerceIn(40, 255)
            c.drawCircle(cx, cy, ring.coerceAtMost(r * 0.95f), p)
        }
    }

    companion object {
        // neutral theme tokens (the app's dark surface); accents for states
        const val SURFACE = 0xF0121318.toInt()
        const val OUTLINE = 0x24FFFFFF
        const val TEXT = 0xFFF5F5F7.toInt()
        const val ACCENT = 0xFF8AB4F8.toInt()       // listening / captions
        const val RECORDING = 0xFFFF453A.toInt()    // system red: recording
        const val AMBER = 0xFFFFB020.toInt()        // 80% of a limit
        const val LOCK = 0xFFFF9F0A.toInt()         // locked feed

        /** y just below the camera cut-out (or the status bar). */
        fun belowCamera(wm: WindowManager, density: Float): Int {
            var y = (24 * density).toInt()
            if (Build.VERSION.SDK_INT >= 30) {
                val insets = wm.currentWindowMetrics.windowInsets
                val bar = insets.getInsets(WindowInsets.Type.statusBars()).top
                if (bar > 0) y = bar
                insets.displayCutout?.boundingRects?.firstOrNull { it.top < 4 * 48 * density }?.let { y = maxOf(y, it.bottom) }
            }
            return y
        }

        val captions = CameraCapsule("Snapy captions")
        val status = CameraCapsule("Snapy status")
    }
}
