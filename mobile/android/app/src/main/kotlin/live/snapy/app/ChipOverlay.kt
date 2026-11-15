package live.snapy.app

import android.animation.AnimatorSet
import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RadialGradient
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowInsets
import android.view.WindowManager
import android.view.animation.AccelerateInterpolator
import android.view.animation.DecelerateInterpolator
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.abs

/**
 * Living AI Orb: rotates harmonic light blobs and shifts through the 6 spectral palettes.
 * When [isHaloRing] is true, clips to a ring encircling the camera punch-hole cutout with a
 * transparent center so the physical camera lens is completely unobstructed.
 */
class LivingOrbView(context: Context) : View(context) {
    var isHaloRing = false
        set(value) { field = value; invalidate() }
    var cutoutRadiusPx = 0f
        set(value) { field = value; invalidate() }
    var isTopNotch = false
        set(value) { field = value; invalidate() }
    var notchWidth = 0f
        set(value) { field = value; invalidate() }
    var notchHeight = 0f
        set(value) { field = value; invalidate() }

    private var dynamicPalette: IntArray? = null

    fun setDynamicPalette(colors: IntArray?) {
        dynamicPalette = colors
        colorAnimator.start()
        invalidate()
    }

    private val palettes = arrayOf(
        intArrayOf(0xFFFFFFFF.toInt(), 0xFF28C8FF.toInt(), 0xFF3CFFC8.toInt(), 0xFF78A0FF.toInt()), // Cyan Electric
        intArrayOf(0xFFFFFFFF.toInt(), 0xFF5E81FF.toInt(), 0xFF966EFF.toInt(), 0xFF46C8FF.toInt()), // Snapy Classic
        intArrayOf(0xFFFFFFFF.toInt(), 0xFFAA5AFF.toInt(), 0xFFFF5AC8.toInt(), 0xFF5A78FF.toInt()), // Ultra Violet
        intArrayOf(0xFFFFFFFF.toInt(), 0xFF5AAAFF.toInt(), 0xFFBEDCFF.toInt(), 0xFF826EFF.toInt()), // Ice Blue
        intArrayOf(0xFFFFFFFF.toInt(), 0xFFFF9F0A.toInt(), 0xFFFF375F.toInt(), 0xFFBF5AF2.toInt()), // Sunset Aura
        intArrayOf(0xFFFFFFFF.toInt(), 0xFF30D158.toInt(), 0xFF00F2FE.toInt(), 0xFF66FF99.toInt()), // Emerald
    )
    private var paletteIndex = 0
    private var colorT = 1f
    private var turnT = 0f
    private val mainHandler = Handler(Looper.getMainLooper())

    private val turnAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
        duration = 9000
        repeatCount = ValueAnimator.INFINITE
        addUpdateListener {
            turnT = it.animatedValue as Float
            invalidate()
        }
    }

    private val colorAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
        duration = 750
        addUpdateListener {
            colorT = it.animatedValue as Float
            invalidate()
        }
    }

    private val cycleRunnable = object : Runnable {
        override fun run() {
            nextPalette()
            mainHandler.postDelayed(this, 6500)
        }
    }

    init {
        turnAnimator.start()
        mainHandler.postDelayed(cycleRunnable, 6500)
    }

    fun nextPalette() {
        paletteIndex = (paletteIndex + 1) % palettes.size
        colorAnimator.start()
    }

    fun stop() {
        turnAnimator.cancel()
        colorAnimator.cancel()
        mainHandler.removeCallbacks(cycleRunnable)
    }

    private fun lerpColor(c1: Int, c2: Int, t: Float): Int {
        val a = ((c1 ushr 24) * (1 - t) + (c2 ushr 24) * t).toInt()
        val r = (((c1 shr 16) and 0xff) * (1 - t) + ((c2 shr 16) and 0xff) * t).toInt()
        val g = (((c1 shr 8) and 0xff) * (1 - t) + ((c2 shr 8) and 0xff) * t).toInt()
        val b = ((c1 and 0xff) * (1 - t) + (c2 and 0xff) * t).toInt()
        return (a shl 24) or (r shl 16) or (g shl 8) or b
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 2f || h <= 2f) return
        val r = minOf(w, h) / 2f
        if (r <= 2f) return
        val cx = w / 2f
        val cy = h / 2f

        try {
            val curr = dynamicPalette ?: palettes[paletteIndex]
            val prev = palettes[(paletteIndex - 1 + palettes.size) % palettes.size]
            val c0 = if (dynamicPalette != null) curr[0] else lerpColor(prev[0], curr[0], colorT)
            val c1 = if (dynamicPalette != null) curr[1] else lerpColor(prev[1], curr[1], colorT)
            val c2 = if (dynamicPalette != null) curr[2] else lerpColor(prev[2], curr[2], colorT)
            val c3 = if (dynamicPalette != null) curr[3] else lerpColor(prev[3], curr[3], colorT)

            if (isTopNotch && notchWidth > 0f && notchHeight > 0f) {
                val nw = notchWidth
                val nh = notchHeight
                val notchPath = Path().apply {
                    moveTo(cx - nw / 2f - 4f, 0f)
                    cubicTo(
                        cx - nw / 2f, nh * 0.75f,
                        cx - nw * 0.35f, nh + 4f,
                        cx, nh + 4f
                    )
                    cubicTo(
                        cx + nw * 0.35f, nh + 4f,
                        cx + nw / 2f, nh * 0.75f,
                        cx + nw / 2f + 4f, 0f
                    )
                }
                val glowStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    style = Paint.Style.STROKE
                    strokeWidth = 3.5f
                    strokeCap = Paint.Cap.ROUND
                    shader = LinearGradient(
                        cx - nw / 2f, 0f, cx + nw / 2f, nh,
                        intArrayOf(c1, c2, c3),
                        floatArrayOf(0.1f, 0.5f, 0.9f),
                        Shader.TileMode.CLAMP
                    )
                }
                canvas.drawPath(notchPath, glowStroke)
                return
            }

            if (isHaloRing && cutoutRadiusPx > 0f) {
                val innerCutout = cutoutRadiusPx.coerceIn(0.5f, (r - 2f).coerceAtLeast(0.5f))
                val ringPath = Path().apply {
                    fillType = Path.FillType.EVEN_ODD
                    addCircle(cx, cy, r, Path.Direction.CW)
                    addCircle(cx, cy, innerCutout, Path.Direction.CW)
                }
                canvas.save()
                canvas.clipPath(ringPath)

                // Halo glow inside the camera ring
                val t = turnT * 2 * Math.PI.toFloat()
                val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    shader = RadialGradient(
                        cx, cy, r.coerceAtLeast(1f),
                        intArrayOf(c1 and 0xCCFFFFFF.toInt(), c2 and 0x88FFFFFF.toInt(), c3 and 0x44FFFFFF.toInt()),
                        floatArrayOf(0.2f, 0.6f, 1f),
                        Shader.TileMode.CLAMP
                    )
                }
                canvas.drawCircle(cx, cy, r, ringPaint)

                // Dynamic rotating light streak around the ring
                val angle = t
                val lx = cx + Math.cos(angle.toDouble()).toFloat() * (r + innerCutout) / 2f
                val ly = cy + Math.sin(angle.toDouble()).toFloat() * (r + innerCutout) / 2f
                val streakRadius = ((r - innerCutout) * 1.6f).coerceAtLeast(1f)
                val streakPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    xfermode = PorterDuffXfermode(PorterDuff.Mode.SCREEN)
                    shader = RadialGradient(
                        lx, ly, streakRadius,
                        intArrayOf(0xFFFFFFFF.toInt(), 0),
                        floatArrayOf(0f, 1f),
                        Shader.TileMode.CLAMP
                    )
                }
                canvas.drawCircle(lx, ly, streakRadius, streakPaint)

                canvas.restore()

                // Outer subtle glowing hairline
                val outerStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    style = Paint.Style.STROKE
                    strokeWidth = 2.5f
                    color = c1 and 0x99FFFFFF.toInt()
                }
                canvas.drawCircle(cx, cy, (r - 1.25f).coerceAtLeast(1f), outerStroke)

                // Crisp inner camera cutout edge
                val innerStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    style = Paint.Style.STROKE
                    strokeWidth = 1.5f
                    color = 0x44FFFFFF.toInt()
                }
                canvas.drawCircle(cx, cy, innerCutout + 0.75f, innerStroke)
                return
            }

            // Solid Living Orb (used inside dropped capsule strip)
            // 1. Soft atmospheric halo
            val haloPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = RadialGradient(
                    cx, cy, r.coerceAtLeast(1f),
                    intArrayOf(c1 and 0x55FFFFFF, c2 and 0x22FFFFFF, 0),
                    floatArrayOf(0.4f, 0.75f, 1.0f),
                    Shader.TileMode.CLAMP
                )
            }
            canvas.drawCircle(cx, cy, r, haloPaint)

            // 2. Base spherical gradient
            val innerR = (r * 0.88f).coerceAtLeast(1f)
            val path = Path().apply { addCircle(cx, cy, innerR, Path.Direction.CW) }
            canvas.save()
            canvas.clipPath(path)

            val basePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = RadialGradient(
                    cx - innerR * 0.25f, cy - innerR * 0.35f, (innerR * 1.1f).coerceAtLeast(1f),
                    intArrayOf(c0, c1),
                    floatArrayOf(0f, 1f),
                    Shader.TileMode.CLAMP
                )
            }
            canvas.drawCircle(cx, cy, innerR, basePaint)

            // 3. Spectral light blobs rotating inside
            val t = turnT * 2 * Math.PI.toFloat()
            val blobColors = intArrayOf(c1, c2, c3)
            val blobRadius = (innerR * 0.75f).coerceAtLeast(1f)
            for (i in 0..2) {
                val a = t + i * 2.1f
                val rr = innerR * (0.35f + 0.1f * Math.sin((t * 0.8f + i).toDouble()).toFloat())
                val px = cx + Math.cos(a.toDouble()).toFloat() * rr
                val py = cy + Math.sin((a * 1.12f).toDouble()).toFloat() * rr
                val blobPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    xfermode = PorterDuffXfermode(PorterDuff.Mode.SCREEN)
                    shader = RadialGradient(
                        px, py, blobRadius,
                        intArrayOf(blobColors[i] and 0xE6FFFFFF.toInt(), 0),
                        floatArrayOf(0f, 1f),
                        Shader.TileMode.CLAMP
                    )
                }
                canvas.drawCircle(px, py, blobRadius, blobPaint)
            }

            // 4. Glassy specular highlight
            val hx = cx - innerR * 0.30f
            val hy = cy - innerR * 0.35f
            val hlRadius = (innerR * 0.45f).coerceAtLeast(1f)
            val hlPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = RadialGradient(
                    hx, hy, hlRadius,
                    intArrayOf(0xAAFFFFFF.toInt(), 0),
                    floatArrayOf(0f, 1f),
                    Shader.TileMode.CLAMP
                )
            }
            canvas.drawCircle(hx, hy, hlRadius, hlPaint)

            canvas.restore()
        } catch (t: Throwable) {
            android.util.Log.e("LivingOrbView", "Draw exception caught", t)
        }
    }
}

/**
 * Vector rendering for social media short video badges:
 *  - Official Instagram Reels sunset gradient glyph (warm orange -> magenta -> purple with clapperboard & play icon)
 *  - YouTube Shorts red glyph
 *  - Native package icon for Snapchat, TikTok, Facebook, etc.
 */
class ReelIconView(context: Context) : View(context) {
    var appPackage: String = "com.instagram.android"
        set(value) {
            field = value
            invalidate()
        }
    var isReelMode: Boolean = true
        set(value) {
            field = value
            invalidate()
        }

    private val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val whiteFill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.FILL
    }
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 1f || h <= 1f) return
        try {
            val r = minOf(w, h)
            val corner = r * 0.28f

            if (!isReelMode) {
                // Real installed application launcher icon (works for any app: WhatsApp, Telegram, Camera, Games, etc.)
                var drawn = false
                try {
                    val pm = context.packageManager
                    val icon = pm.getApplicationIcon(appPackage)
                    val path = Path().apply {
                        addRoundRect(0f, 0f, w, h, corner, corner, Path.Direction.CW)
                    }
                    canvas.save()
                    canvas.clipPath(path)
                    icon.setBounds(0, 0, w.toInt(), h.toInt())
                    icon.draw(canvas)
                    canvas.restore()
                    drawn = true
                } catch (_: Exception) {}

                if (!drawn) {
                    bgPaint.shader = null
                    bgPaint.color = 0xFF28C8FF.toInt()
                    canvas.drawRoundRect(0f, 0f, w, h, corner, corner, bgPaint)
                    val circleR = r * 0.28f
                    canvas.drawCircle(w / 2f, h / 2f, circleR, whiteFill)
                }
                return
            }

            if (appPackage.contains("instagram")) {
                // Instagram Sunset Gradient: #F58529 -> #DD2A7B -> #8134AF
                bgPaint.shader = LinearGradient(
                    0f, h, w, 0f,
                    intArrayOf(0xFFF58529.toInt(), 0xFFDD2A7B.toInt(), 0xFF8134AF.toInt()),
                    floatArrayOf(0f, 0.5f, 1f),
                    Shader.TileMode.CLAMP
                )
                canvas.drawRoundRect(0f, 0f, w, h, corner, corner, bgPaint)

                // Clapper top separator
                strokePaint.strokeWidth = r * 0.08f
                val clapperY = h * 0.30f
                canvas.drawLine(w * 0.16f, clapperY, w * 0.84f, clapperY, strokePaint)

                // Clapper diagonal slashes
                strokePaint.strokeWidth = r * 0.06f
                canvas.drawLine(w * 0.32f, clapperY, w * 0.40f, h * 0.12f, strokePaint)
                canvas.drawLine(w * 0.58f, clapperY, w * 0.66f, h * 0.12f, strokePaint)

                // Center Play triangle
                val playPath = Path().apply {
                    val cx = w * 0.52f
                    val cy = h * 0.62f
                    val sz = r * 0.18f
                    moveTo(cx - sz * 0.7f, cy - sz)
                    lineTo(cx + sz, cy)
                    lineTo(cx - sz * 0.7f, cy + sz)
                    close()
                }
                canvas.drawPath(playPath, whiteFill)
            } else if (appPackage.contains("youtube")) {
                // YouTube Shorts Red
                bgPaint.shader = null
                bgPaint.color = 0xFFFF0000.toInt()
                canvas.drawRoundRect(0f, 0f, w, h, corner, corner, bgPaint)

                // Play Triangle
                val playPath = Path().apply {
                    val cx = w * 0.53f
                    val cy = h * 0.50f
                    val sz = r * 0.24f
                    moveTo(cx - sz * 0.8f, cy - sz)
                    lineTo(cx + sz, cy)
                    lineTo(cx - sz * 0.8f, cy + sz)
                    close()
                }
                canvas.drawPath(playPath, whiteFill)
            } else {
                var drawn = false
                try {
                    val pm = context.packageManager
                    val icon = pm.getApplicationIcon(appPackage)
                    val path = Path().apply {
                        addRoundRect(0f, 0f, w, h, corner, corner, Path.Direction.CW)
                    }
                    canvas.save()
                    canvas.clipPath(path)
                    icon.setBounds(0, 0, w.toInt(), h.toInt())
                    icon.draw(canvas)
                    canvas.restore()
                    drawn = true
                } catch (_: Exception) {}

                if (!drawn) {
                    bgPaint.shader = LinearGradient(0f, 0f, w, h, 0xFFFF9500.toInt(), 0xFFFF5E3A.toInt(), Shader.TileMode.CLAMP)
                    canvas.drawRoundRect(0f, 0f, w, h, corner, corner, bgPaint)
                    val playPath = Path().apply {
                        val cx = w * 0.53f
                        val cy = h * 0.50f
                        val sz = r * 0.22f
                        moveTo(cx - sz * 0.8f, cy - sz)
                        lineTo(cx + sz, cy)
                        lineTo(cx - sz * 0.8f, cy + sz)
                        close()
                    }
                    canvas.drawPath(playPath, whiteFill)
                }
            }
        } catch (t: Throwable) {
            android.util.Log.e("ReelIconView", "Draw error", t)
        }
    }
}

/**
 * Real Count camera overlay:
 *  - Idle State: glowing halo ring directly encircling the front camera punch-hole cutout
 *  - Active Social State: badge slides in beside the camera ring showing current app's Reel icon + total reels scrolled today
 *  - Drop Interaction: tapping camera halo smoothly unrolls a compact horizontal capsule strip (reference media_1794761463384_f466c5eb.png)
 *    Left target -> opens Snapy AI bottom sheet; Right target -> launches the social app.
 */
class RecordingDotView(context: Context) : View(context) {
    var isRecording = false
        set(value) { field = value; invalidate() }

    private val outerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 2.5f
        color = 0x88FF3B30.toInt()
    }
    private val innerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = 0xFFFF3B30.toInt()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val cx = width / 2f
        val cy = height / 2f
        val r = minOf(cx, cy) - 2f
        if (isRecording) {
            canvas.drawCircle(cx, cy, r, outerPaint)
            canvas.drawCircle(cx, cy, r * 0.55f, innerPaint)
        } else {
            canvas.drawCircle(cx, cy, r * 0.75f, outerPaint)
            canvas.drawCircle(cx, cy, r * 0.45f, innerPaint)
        }
    }
}

class ChipOverlay(
    private val ctx: Context,
    private val wm: WindowManager,
    private val windowType: Int,
    private val cb: Callbacks
) {
    interface Callbacks {
        fun onOpenSheet()
        fun onLaunchApp(pkg: String)
        fun onTakeNote()
        fun onLongPress()
        fun onSwipeDown()
        fun onFullscreen(fullscreen: Boolean)
    }

    private val main = Handler(Looper.getMainLooper())
    private val prefs = RcPrefs(ctx)

    private var root: LinearLayout? = null
    private var haloContainer: FrameLayout? = null
    private var cameraHalo: LivingOrbView? = null
    private var socialBadge: LinearLayout? = null
    private var badgeIcon: ReelIconView? = null
    private var badgeCountText: TextView? = null

    private var capsuleOverlay: View? = null
    private var stripTitleText: TextView? = null
    private var stripTimeText: TextView? = null
    private var stripReelText: TextView? = null
    private var stripReelIcon: ReelIconView? = null
    private var noteDotView: RecordingDotView? = null
    private var noteText: TextView? = null

    private var isSocialActive = false
    private var activeSocialPkg = "com.instagram.android"
    private var activeAppPkg = ""
    private var currentAppMs = 0L
    private var appSessionStartMs = 0L
    private var totalReels = 0
    private var screenTimeStr = "0m"

    fun formatAppTime(ms: Long): String {
        val totalMinutes = (ms / 60000L).coerceAtLeast(0L)
        return if (totalMinutes >= 60) {
            val h = totalMinutes / 60
            val m = totalMinutes % 60
            "${h}h ${m}m"
        } else {
            "${maxOf(1, totalMinutes)}m"
        }
    }

    private var lp: WindowManager.LayoutParams? = null
    private var scale = 1f
    var y: Int = 0; private set
    var height: Int = 0; private set

    private fun dp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v * scale, ctx.resources.displayMetrics).toInt()

    val isShown get() = root != null

    fun show(rules: RealCountRules) {
        if (root != null) return
        val size = if (prefs.bool("simple_mode")) rules.s("chip.simple_mode_size", "large") else prefs.str("chip_size")
        scale = rules.d("chip.sizes.$size", 1.0).toFloat()

        val r = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            clipChildren = false
            clipToPadding = false
        }

        // 1. Camera Touch Area & Punch-Hole Halo Ring
        val haloBox = FrameLayout(ctx).apply {
            val sz = dp(32f)
            layoutParams = LinearLayout.LayoutParams(sz, sz)
            clipChildren = false
            clipToPadding = false
        }
        haloContainer = haloBox

        val halo = LivingOrbView(ctx).apply {
            isHaloRing = true
            layoutParams = FrameLayout.LayoutParams(dp(28f), dp(28f), Gravity.CENTER)
        }
        cameraHalo = halo
        haloBox.addView(halo)
        r.addView(haloBox)

        // 2. Active App / Reel Badge (positioned directly 1px below camera ring)
        val badge = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            visibility = if (isSocialActive || activeAppPkg.isNotEmpty()) View.VISIBLE else View.GONE
            setPadding(dp(5f), dp(1.5f), dp(6f), dp(1.5f))
            background = GradientDrawable().apply {
                cornerRadius = dp(9f).toFloat()
                setColor(0xEE161824.toInt())
                setStroke(dp(1f), 0x2EFFFFFF)
            }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                dp(19f)
            ).apply {
                topMargin = dp(1f) // Exactly 1-2 pixels below camera ring!
            }

            val icon = ReelIconView(ctx).apply {
                appPackage = activeSocialPkg
                layoutParams = LinearLayout.LayoutParams(dp(13f), dp(13f)).apply {
                    rightMargin = dp(3.5f)
                }
            }
            badgeIcon = icon
            addView(icon)

            val tv = TextView(ctx).apply {
                text = if (isSocialActive && totalReels > 0) "$totalReels" else formatAppTime(currentAppMs)
                setTextColor(0xFFFFFFFF.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 10.5f * scale)
                typeface = Typeface.create("sans-serif-bold", Typeface.BOLD)
                fontFeatureSettings = "tnum"
            }
            badgeCountText = tv
            addView(tv)

            isClickable = true
            isFocusable = true
            setOnClickListener { toggleCapsuleStrip() }
        }
        socialBadge = badge
        r.addView(badge)

        attachGestures(haloBox)

        val p = WindowManager.LayoutParams(
            dp(54f),
            WindowManager.LayoutParams.WRAP_CONTENT,
            windowType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        )
        p.gravity = Gravity.TOP or Gravity.START
        if (Build.VERSION.SDK_INT >= 30) {
            p.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        } else if (Build.VERSION.SDK_INT >= 28) {
            p.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        lp = p

        if (Build.VERSION.SDK_INT >= 30) {
            r.setOnApplyWindowInsetsListener { v, insets ->
                cb.onFullscreen(!insets.isVisible(WindowInsets.Type.statusBars()))
                v.onApplyWindowInsets(insets)
            }
        }

        try { wm.addView(r, p) } catch (_: Exception) { return }
        root = r
        place(rules)
    }

    fun remove() {
        dismissCapsuleStrip()
        dismissFloatingSubtitle()
        cameraHalo?.stop()
        root?.let { try { wm.removeView(it) } catch (_: Exception) { } }
        root = null
    }

    fun rebuild(rules: RealCountRules) { remove(); show(rules) }

    data class CutoutData(
        val hasCutout: Boolean,
        val bounds: Rect,
        val cx: Int,
        val cy: Int,
        val size: Int,
        val isTopNotch: Boolean = false,
        val isCorner: Boolean = false
    )

    private fun getCutout(): CutoutData {
        val dm = ctx.resources.displayMetrics
        if (Build.VERSION.SDK_INT >= 30) {
            val insets = wm.currentWindowMetrics.windowInsets
            val cutout = insets.displayCutout
            if (cutout != null && cutout.boundingRects.isNotEmpty()) {
                val r = cutout.boundingRects[0]
                val sz = minOf(r.width(), r.height()).coerceIn(dp(18f), dp(36f))
                val isTopNotch = (r.top <= 2 && r.width() > dp(85f) && r.width() > r.height() * 2.2f)
                val isCorner = (r.centerX() < dm.widthPixels * 0.35f || r.centerX() > dm.widthPixels * 0.65f)
                val cy = if (r.top <= 2 && !isTopNotch) {
                    (r.top + r.height() / 2).coerceAtLeast(sz / 2)
                } else {
                    r.centerY()
                }
                return CutoutData(true, r, r.centerX(), cy, sz, isTopNotch, isCorner)
            }
        } else if (Build.VERSION.SDK_INT >= 28) {
            @Suppress("DEPRECATION")
            val cutout = wm.defaultDisplay.cutout
            if (cutout != null && cutout.boundingRects.isNotEmpty()) {
                val r = cutout.boundingRects[0]
                val sz = minOf(r.width(), r.height()).coerceIn(dp(18f), dp(36f))
                val isTopNotch = (r.top <= 2 && r.width() > dp(85f) && r.width() > r.height() * 2.2f)
                val isCorner = (r.centerX() < dm.widthPixels * 0.35f || r.centerX() > dm.widthPixels * 0.65f)
                val cy = if (r.top <= 2 && !isTopNotch) {
                    (r.top + r.height() / 2).coerceAtLeast(sz / 2)
                } else {
                    r.centerY()
                }
                return CutoutData(true, r, r.centerX(), cy, sz, isTopNotch, isCorner)
            }
        }
        val defaultSize = dp(24f)
        var bar = dp(4f)
        if (Build.VERSION.SDK_INT >= 30) {
            val b = wm.currentWindowMetrics.windowInsets.getInsets(WindowInsets.Type.statusBars()).top
            if (b > 0) bar = ((b - defaultSize) / 2).coerceAtLeast(0)
        }
        return CutoutData(false, Rect(dm.widthPixels / 2 - defaultSize / 2, bar, dm.widthPixels / 2 + defaultSize / 2, bar + defaultSize), dm.widthPixels / 2, bar + defaultSize / 2, defaultSize)
    }

    fun place(rules: RealCountRules) {
        val r = root ?: return
        val p = lp ?: return
        try {
            val cutout = getCutout()
            val dm = ctx.resources.displayMetrics

            if (cutout.isTopNotch) {
                cameraHalo?.apply {
                    isHaloRing = false
                    isTopNotch = true
                    notchWidth = cutout.bounds.width().toFloat()
                    notchHeight = cutout.bounds.height().toFloat()
                    layoutParams = FrameLayout.LayoutParams(cutout.bounds.width() + dp(12f), cutout.bounds.height() + dp(8f), Gravity.CENTER_HORIZONTAL or Gravity.TOP)
                }
                val hitW = cutout.bounds.width() + dp(12f)
                val hitH = cutout.bounds.height() + dp(8f)
                haloContainer?.layoutParams = LinearLayout.LayoutParams(hitW, hitH)
                p.x = (cutout.cx - hitW / 2).coerceIn(0, (dm.widthPixels - hitW).coerceAtLeast(0))
                p.y = 0
            } else {
                val haloSize = if (cutout.hasCutout) {
                    maxOf(cutout.size, dp(26f)) + dp(4f)
                } else {
                    dp(28f)
                }

                cameraHalo?.apply {
                    isTopNotch = false
                    isHaloRing = true
                    cutoutRadiusPx = if (cutout.hasCutout) {
                        (cutout.size / 2f).coerceIn(dp(6f).toFloat(), dp(16f).toFloat())
                    } else {
                        dp(6.5f).toFloat()
                    }
                    layoutParams = FrameLayout.LayoutParams(haloSize, haloSize, Gravity.CENTER)
                }

                val touchW = maxOf(haloSize, dp(48f))
                haloContainer?.layoutParams = LinearLayout.LayoutParams(touchW, haloSize)
                p.x = (cutout.cx - touchW / 2).coerceIn(0, (dm.widthPixels - touchW).coerceAtLeast(0))
                p.y = (cutout.cy - haloSize / 2).coerceAtLeast(0)
            }

            p.width = WindowManager.LayoutParams.WRAP_CONTENT
            p.height = WindowManager.LayoutParams.WRAP_CONTENT

            y = p.y
            height = p.height
            wm.updateViewLayout(r, p)
        } catch (_: Exception) { }
    }

    // ------------------------------------------------------------------ Dynamic Palette & Mode
    fun setDynamicPalette(colors: IntArray?) = main.post {
        cameraHalo?.setDynamicPalette(colors)
    }

    fun setReelFeedMode(pkg: String, reels: Int) = main.post {
        isSocialActive = true
        activeAppPkg = pkg
        if (pkg.isNotEmpty()) activeSocialPkg = pkg
        totalReels = reels
        badgeIcon?.isReelMode = true
        badgeIcon?.appPackage = pkg
        badgeCountText?.text = "$totalReels"
        stripReelIcon?.isReelMode = true
        stripReelIcon?.appPackage = pkg
        stripReelText?.text = "$totalReels reels"
        socialBadge?.visibility = View.VISIBLE
        animateReelNumberDrop()
    }

    fun setAppFeedMode(pkg: String, appMs: Long) = main.post {
        isSocialActive = false
        activeAppPkg = pkg
        currentAppMs = appMs
        if (pkg.isNotEmpty()) activeSocialPkg = pkg
        badgeIcon?.isReelMode = false
        badgeIcon?.appPackage = pkg
        val timeText = formatAppTime(appMs)
        badgeCountText?.text = timeText
        stripReelIcon?.isReelMode = false
        stripReelIcon?.appPackage = pkg
        stripReelText?.text = timeText
        val badge = socialBadge ?: return@post
        if (pkg.isEmpty() || pkg == ctx.packageName || pkg == "com.android.systemui") {
            badge.visibility = View.GONE
        } else {
            badge.visibility = View.VISIBLE
        }
    }

    // ------------------------------------------------------------------ Active App & Social Badge
    fun setActiveApp(pkg: String, isSocial: Boolean, reels: Int) = main.post {
        activeAppPkg = pkg
        isSocialActive = isSocial
        totalReels = reels
        if (isSocial) {
            if (pkg.isNotEmpty()) activeSocialPkg = pkg
            badgeIcon?.isReelMode = true
            badgeIcon?.appPackage = pkg
            badgeCountText?.text = "$totalReels"
            stripReelIcon?.isReelMode = true
            stripReelIcon?.appPackage = pkg
        } else {
            if (pkg.isNotEmpty()) {
                activeSocialPkg = pkg
                badgeIcon?.isReelMode = false
                badgeIcon?.appPackage = pkg
            }
            appSessionStartMs = System.currentTimeMillis()
            badgeCountText?.text = "⏱ 0m"
        }
        val badge = socialBadge ?: return@post
        if (pkg.isEmpty() || pkg == ctx.packageName || pkg == "com.android.systemui") {
            badge.visibility = View.GONE
        } else {
            badge.visibility = View.VISIBLE
        }
    }

    fun setSocialActive(active: Boolean, pkg: String, reels: Int) = setActiveApp(pkg, active, reels)

    fun onReelCounted(pkg: String, reels: Int) = main.post {
        totalReels = reels
        activeSocialPkg = pkg
        badgeIcon?.isReelMode = true
        badgeIcon?.appPackage = pkg
        stripReelIcon?.isReelMode = true
        stripReelIcon?.appPackage = pkg

        animateReelNumberDrop()
        flashReelFeedback()
    }

    private fun animateReelNumberDrop() {
        val badge = socialBadge ?: return
        val tv = badgeCountText ?: return
        if (badge.visibility != View.VISIBLE) badge.visibility = View.VISIBLE
        tv.animate()
            .translationY(-dp(8f).toFloat())
            .alpha(0f)
            .setDuration(110)
            .withEndAction {
                tv.text = "$totalReels"
                tv.translationY = dp(8f).toFloat()
                tv.animate()
                    .translationY(0f)
                    .alpha(1f)
                    .setDuration(140)
                    .setInterpolator(DecelerateInterpolator(1.6f))
                    .start()
            }
            .start()
    }

    private fun flashReelFeedback() {
        stripReelText?.text = "$totalReels"
        val title = stripTitleText ?: return
        title.text = "+1 Reel"
        title.setTextColor(0xFF3CFFC8.toInt())
        main.removeCallbacks(revertTitleRunnable)
        main.postDelayed(revertTitleRunnable, 1800)
    }

    private val revertTitleRunnable = Runnable {
        stripTitleText?.text = "Real Count"
        stripTitleText?.setTextColor(0xFFFFFFFF.toInt())
    }

    fun updateMetrics(time: String, reels: Int) = main.post {
        screenTimeStr = time
        totalReels = reels
        badgeCountText?.text = if (isSocialActive && totalReels > 0) "$totalReels" else formatAppTime(currentAppMs)
        stripReelText?.text = if (isSocialActive && totalReels > 0) "$totalReels reels" else formatAppTime(currentAppMs)
    }

    fun render(time: String, count: String, tone: ChipTone, ring: Float, desc: String) = main.post {
        screenTimeStr = time
        val rCount = count.filter { it.isDigit() }.toIntOrNull() ?: totalReels
        totalReels = rCount
        badgeCountText?.text = if (isSocialActive && totalReels > 0) "$totalReels" else formatAppTime(currentAppMs)
        stripReelText?.text = if (isSocialActive && totalReels > 0) "$totalReels reels" else formatAppTime(currentAppMs)
    }

    fun setHidden(hidden: Boolean) = main.post { root?.visibility = if (hidden) View.GONE else View.VISIBLE }

    fun voice(text: String) = main.post {
        root?.visibility = View.VISIBLE
        stripTitleText?.text = text.takeLast(20)
        showFloatingSubtitle(text)
    }

    private var subtitleOverlay: View? = null
    private var subtitleText: TextView? = null
    private val hideSubtitleRunnable = Runnable { dismissFloatingSubtitle() }

    /**
     * Floating Subtitle HUD: compact micro-capsule directly beneath front camera cutout.
     * Shows small typography (11.5sp) live while AI is speaking / processing.
     */
    fun showFloatingSubtitle(text: String) {
        val clean = text.trim()
        if (clean.isEmpty()) {
            main.postDelayed(hideSubtitleRunnable, 1800)
            return
        }
        main.removeCallbacks(hideSubtitleRunnable)
        val cutout = getCutout()

        if (subtitleOverlay == null) {
            val tv = TextView(ctx).apply {
                setTextColor(0xFFFFFFFF.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f * scale)
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                maxLines = 2
                setPadding(dp(10f), dp(4f), dp(10f), dp(4f))
            }
            subtitleText = tv

            val layout = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                background = GradientDrawable().apply {
                    cornerRadius = dp(14f).toFloat()
                    setColor(0xF012131A.toInt())
                    setStroke(dp(1f), 0x24FFFFFF)
                }
                elevation = dp(8f).toFloat()

                // Tiny glowing cyan/electric indicator dot
                val dot = View(ctx).apply {
                    layoutParams = LinearLayout.LayoutParams(dp(6f), dp(6f)).apply {
                        leftMargin = dp(8f)
                    }
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.OVAL
                        setColor(0xFF28C8FF.toInt())
                    }
                }
                addView(dot)
                addView(tv)
            }
            subtitleOverlay = layout

            val lp = WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT
            ).apply {
                gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                y = cutout.cy + (if (cutout.hasCutout) cutout.size / 2 else dp(14f)) + dp(6f)
            }
            try {
                wm.addView(layout, lp)
                layout.alpha = 0f
                layout.translationY = -dp(6f).toFloat()
                layout.animate().alpha(1f).translationY(0f).setDuration(160).start()
            } catch (_: Exception) {}
        }

        subtitleText?.text = clean
        main.postDelayed(hideSubtitleRunnable, 3500)
    }

    fun dismissFloatingSubtitle() {
        val v = subtitleOverlay ?: return
        v.animate().alpha(0f).translationY(-dp(6f).toFloat()).setDuration(160).withEndAction {
            try { wm.removeView(v) } catch (_: Exception) {}
            if (subtitleOverlay == v) {
                subtitleOverlay = null
                subtitleText = null
            }
        }.start()
    }

    fun pulse() = main.post {
        val r = root ?: return@post
        AnimatorSet().apply {
            playTogether(
                ObjectAnimator.ofFloat(r, "scaleX", 1f, 1.08f, 1f, 1.08f, 1f),
                ObjectAnimator.ofFloat(r, "scaleY", 1f, 1.08f, 1f, 1.08f, 1f),
            )
            duration = 1200
            start()
        }
    }

    // ------------------------------------------------------------------ Dropped Capsule Strip
    fun toggleCapsuleStrip() {
        if (capsuleOverlay != null) dismissCapsuleStrip() else showCapsuleStrip()
    }

    fun dismissCapsuleStrip() {
        val strip = capsuleOverlay ?: return
        strip.animate()
            .scaleX(0.25f)
            .scaleY(0.1f)
            .translationY(-dp(16f).toFloat())
            .alpha(0f)
            .setDuration(180)
            .setInterpolator(AccelerateInterpolator(1.4f))
            .withEndAction {
                try { wm.removeView(strip) } catch (_: Exception) {}
                if (capsuleOverlay == strip) {
                    capsuleOverlay = null
                    stripTitleText = null
                    stripTimeText = null
                    stripReelText = null
                    stripReelIcon = null
                    noteDotView = null
                    noteText = null
                }
            }
            .start()
    }

    private fun showCapsuleStrip() {
        dismissCapsuleStrip()
        val dm = ctx.resources.displayMetrics
        val capsuleW = minOf(dm.widthPixels - dp(24f), dp(320f))

        // Horizontal obsidian capsule
        val stripRoot = LinearLayout(ctx).apply {
            id = android.R.id.content
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8f), dp(4f), dp(10f), dp(4f))
            background = GradientDrawable().apply {
                cornerRadius = dp(22f).toFloat()
                setColor(0xF212131A.toInt()) // Deep obsidian glass
                setStroke(dp(1f), 0x24FFFFFF) // 1dp subtle hairline
            }
            elevation = dp(12f).toFloat()
        }

        // 1. Left Target: Snapy AI Living Orb (Touch -> opens AI Bottom Sheet)
        val leftSection = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4f), dp(2f), dp(4f), dp(2f))
            isClickable = true
            isFocusable = true
            background = GradientDrawable().apply {
                cornerRadius = dp(16f).toFloat()
                setColor(0x00000000)
            }

            // Living AI Orb (solid 3D sphere)
            val orb = LivingOrbView(ctx).apply {
                isHaloRing = false
                layoutParams = LinearLayout.LayoutParams(dp(26f), dp(26f))
            }
            addView(orb)

            setOnClickListener {
                dismissCapsuleStrip()
                cb.onOpenSheet()
            }
        }
        stripRoot.addView(leftSection)

        // 2. Note Section [🔴 Note] (Touch -> starts silent audio note / recording)
        val noteSection = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8f), dp(3.5f), dp(9f), dp(3.5f))
            isClickable = true
            isFocusable = true
            background = GradientDrawable().apply {
                cornerRadius = dp(14f).toFloat()
                setColor(0x28FFFFFF)
                setStroke(dp(1f), 0x33FFFFFF)
            }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                leftMargin = dp(6f)
                rightMargin = dp(6f)
            }

            // Red dot with ring around it
            val redDot = RecordingDotView(ctx).apply {
                isRecording = AudioNoteRecorder.isRecording
                layoutParams = LinearLayout.LayoutParams(dp(14f), dp(14f)).apply {
                    rightMargin = dp(5f)
                }
            }
            noteDotView = redDot
            addView(redDot)

            val noteTv = TextView(ctx).apply {
                text = if (AudioNoteRecorder.isRecording) "Recording..." else "Note"
                setTextColor(0xFFFFFFFF.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f * scale)
                typeface = Typeface.create("sans-serif-bold", Typeface.BOLD)
            }
            noteText = noteTv
            addView(noteTv)

            AudioNoteRecorder.onTimerTick = { s ->
                main.post {
                    val m = s / 60
                    val sec = s % 60
                    noteTv.text = String.format(java.util.Locale.US, "Rec %d:%02d", m, sec)
                    redDot.isRecording = true
                }
            }

            setOnClickListener {
                if (AudioNoteRecorder.isRecording) {
                    val f = AudioNoteRecorder.stop(ctx)
                    redDot.isRecording = false
                    noteTv.text = "Note"
                    if (f != null) {
                        android.widget.Toast.makeText(ctx, "✓ Audio note saved to Conscious Vault", android.widget.Toast.LENGTH_SHORT).show()
                    }
                } else {
                    val ok = AudioNoteRecorder.start(ctx)
                    if (ok) {
                        redDot.isRecording = true
                        noteTv.text = "Rec 0:00"
                        android.widget.Toast.makeText(ctx, "🎙 Taking audio note silently...", android.widget.Toast.LENGTH_SHORT).show()
                    }
                }
            }
        }
        stripRoot.addView(noteSection)

        // 3. Middle: Divider
        val divider = View(ctx).apply {
            layoutParams = LinearLayout.LayoutParams(dp(1f), dp(16f)).apply {
                leftMargin = dp(4f)
                rightMargin = dp(8f)
            }
            setBackgroundColor(0x2AFFFFFF)
        }
        stripRoot.addView(divider)

        // 4. Right: App Icon & Metric (Reels count or App Screen Time)
        val rightSection = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(6f), dp(2f), dp(6f), dp(2f))
            isClickable = true
            isFocusable = true
            background = GradientDrawable().apply {
                cornerRadius = dp(16f).toFloat()
                setColor(0x00000000)
            }

            val reelIcon = ReelIconView(ctx).apply {
                appPackage = activeSocialPkg
                isReelMode = isSocialActive && totalReels > 0
                layoutParams = LinearLayout.LayoutParams(dp(18f), dp(18f))
            }
            stripReelIcon = reelIcon
            addView(reelIcon)

            val countTv = TextView(ctx).apply {
                val dataText = if (isSocialActive && totalReels > 0) "$totalReels reels" else formatAppTime(currentAppMs)
                text = dataText
                setTextColor(0xFFFFFFFF.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f * scale)
                typeface = Typeface.create("sans-serif-bold", Typeface.BOLD)
                fontFeatureSettings = "tnum"
                setPadding(dp(5f), 0, 0, 0)
            }
            stripReelText = countTv
            addView(countTv)

            setOnClickListener {
                dismissCapsuleStrip()
                cb.onLaunchApp(activeSocialPkg)
            }
        }
        stripRoot.addView(rightSection)

        // Position directly below camera punch-hole
        val cutout = getCutout()
        val topY = if (cutout.hasCutout) cutout.cy + (cutout.size / 2) + dp(6f) else dp(44f)

        val p = WindowManager.LayoutParams(
            capsuleW,
            dp(44f),
            windowType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            y = topY
        }
        if (Build.VERSION.SDK_INT >= 30) {
            p.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        }

        stripRoot.setOnTouchListener { _, event ->
            if (event.actionMasked == MotionEvent.ACTION_OUTSIDE) {
                dismissCapsuleStrip()
                return@setOnTouchListener false
            }
            false
        }

        try {
            wm.addView(stripRoot, p)
            capsuleOverlay = stripRoot
        } catch (_: Throwable) {
            return
        }

        // Fluid spring drop and expand from camera
        stripRoot.pivotX = capsuleW / 2f
        stripRoot.pivotY = 0f
        stripRoot.scaleX = 0.25f
        stripRoot.scaleY = 0.1f
        stripRoot.translationY = -dp(18f).toFloat()
        stripRoot.alpha = 0f

        stripRoot.animate()
            .scaleX(1.0f)
            .scaleY(1.0f)
            .translationY(0f)
            .alpha(1.0f)
            .setDuration(260)
            .setInterpolator(DecelerateInterpolator(2.0f))
            .start()
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun attachGestures(v: View) {
        val slop = ViewConfiguration.get(ctx).scaledTouchSlop
        val longMs = ViewConfiguration.getLongPressTimeout().toLong()
        var downX = 0f; var downY = 0f; var startX = 0; var startY = 0
        var dragging = false; var longFired = false
        var vt: VelocityTracker? = null
        val longPress = Runnable { longFired = true; cb.onLongPress() }
        v.setOnTouchListener { _, e ->
            val p = lp ?: return@setOnTouchListener false
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = e.rawX; downY = e.rawY; startX = p.x; startY = p.y
                    dragging = false; longFired = false
                    vt?.recycle(); vt = VelocityTracker.obtain().also { it.addMovement(e) }
                    main.postDelayed(longPress, longMs)
                }
                MotionEvent.ACTION_MOVE -> {
                    vt?.addMovement(e)
                    val dx = e.rawX - downX; val dy = e.rawY - downY
                    if (!dragging && (abs(dx) > slop * 2.5f || abs(dy) > slop * 2.5f)) { dragging = true; main.removeCallbacks(longPress) }
                    if (dragging && !longFired) {
                        p.x = (startX + dx).toInt().coerceAtLeast(0); p.y = (startY + dy).toInt().coerceAtLeast(0)
                        try { wm.updateViewLayout(v, p) } catch (_: Exception) { }
                    }
                }
                MotionEvent.ACTION_UP -> {
                    main.removeCallbacks(longPress)
                    val t = vt; vt = null
                    t?.addMovement(e); t?.computeCurrentVelocity(1000)
                    val vy = t?.yVelocity ?: 0f
                    t?.recycle()
                    val dy = e.rawY - downY; val dx = e.rawX - downX
                    val dpPerS = vy / ctx.resources.displayMetrics.density
                    when {
                        longFired -> {}
                        dragging && dpPerS > 900 && dy > 0 && abs(dx) < dy -> {
                            p.x = startX; p.y = startY
                            try { wm.updateViewLayout(v, p) } catch (_: Exception) { }
                            cb.onSwipeDown()
                        }
                        dragging -> { prefs.update(org.json.JSONObject().put("chip_x", p.x).put("chip_y", p.y)); y = p.y }
                        else -> {
                            cameraHalo?.nextPalette()
                            toggleCapsuleStrip()
                        }
                    }
                }
                MotionEvent.ACTION_CANCEL -> { main.removeCallbacks(longPress); vt?.recycle(); vt = null }
            }
            true
        }
    }
}

/**
 * Legacy popup cards have been permanently removed per user requirement.
 * Alerts, nudges, and reel lock status now appear via the camera capsule strip
 * and floating subtitle HUD without intrusive full-screen blocking cards.
 */
class OverlayCards(private val ctx: Context, private val wm: WindowManager, private val windowType: Int) {
    fun show(title: String?, body: String, actions: List<Pair<String, String>>, belowY: Int, timeoutMs: Long,
             bigText: Boolean = false, onAction: (String) -> Unit) {
        // No-op: legacy popup cards removed per user architecture.
    }

    fun remove() {
        // No-op
    }
}
