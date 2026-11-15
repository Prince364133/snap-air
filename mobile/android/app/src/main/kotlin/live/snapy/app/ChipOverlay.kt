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
        val r = minOf(w, h) / 2f
        val cx = w / 2f
        val cy = h / 2f

        val prev = palettes[(paletteIndex - 1 + palettes.size) % palettes.size]
        val curr = palettes[paletteIndex]
        val c0 = lerpColor(prev[0], curr[0], colorT)
        val c1 = lerpColor(prev[1], curr[1], colorT)
        val c2 = lerpColor(prev[2], curr[2], colorT)
        val c3 = lerpColor(prev[3], curr[3], colorT)

        if (isHaloRing && cutoutRadiusPx > 0f) {
            val innerCutout = cutoutRadiusPx.coerceAtMost(r - 3f)
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
                    cx, cy, r,
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
            val streakPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                xfermode = PorterDuffXfermode(PorterDuff.Mode.SCREEN)
                shader = RadialGradient(
                    lx, ly, (r - innerCutout) * 1.6f,
                    intArrayOf(0xFFFFFFFF.toInt(), 0),
                    floatArrayOf(0f, 1f),
                    Shader.TileMode.CLAMP
                )
            }
            canvas.drawCircle(lx, ly, (r - innerCutout) * 1.6f, streakPaint)

            canvas.restore()

            // Outer subtle glowing hairline
            val outerStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = 2.5f
                color = c1 and 0x99FFFFFF.toInt()
            }
            canvas.drawCircle(cx, cy, r - 1.25f, outerStroke)

            // Crisp inner camera cutout edge
            val innerStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = 1.5f
                color = 0x44FFFFFF.toInt()
            }
            canvas.drawCircle(cx, cy, innerCutout + 0.75f, innerStroke)
            return
        }

        // 1. Soft atmospheric halo
        val haloPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = RadialGradient(
                cx, cy, r,
                intArrayOf(c1 and 0x55FFFFFF, c2 and 0x22FFFFFF, 0),
                floatArrayOf(0.4f, 0.75f, 1.0f),
                Shader.TileMode.CLAMP
            )
        }
        canvas.drawCircle(cx, cy, r, haloPaint)

        // 2. Base spherical gradient
        val innerR = r * 0.88f
        val path = Path().apply { addCircle(cx, cy, innerR, Path.Direction.CW) }
        canvas.save()
        canvas.clipPath(path)

        val basePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = RadialGradient(
                cx - innerR * 0.25f, cy - innerR * 0.35f, innerR * 1.1f,
                intArrayOf(c0, c1),
                floatArrayOf(0f, 1f),
                Shader.TileMode.CLAMP
            )
        }
        canvas.drawCircle(cx, cy, innerR, basePaint)

        // 3. Spectral light blobs rotating inside
        val t = turnT * 2 * Math.PI.toFloat()
        val blobColors = intArrayOf(c1, c2, c3)
        for (i in 0..2) {
            val a = t + i * 2.1f
            val rr = innerR * (0.35f + 0.1f * Math.sin((t * 0.8f + i).toDouble()).toFloat())
            val px = cx + Math.cos(a.toDouble()).toFloat() * rr
            val py = cy + Math.sin((a * 1.12f).toDouble()).toFloat() * rr
            val blobPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                xfermode = PorterDuffXfermode(PorterDuff.Mode.SCREEN)
                shader = RadialGradient(
                    px, py, innerR * 0.75f,
                    intArrayOf(blobColors[i] and 0xE6FFFFFF.toInt(), 0),
                    floatArrayOf(0f, 1f),
                    Shader.TileMode.CLAMP
                )
            }
            canvas.drawCircle(px, py, innerR * 0.75f, blobPaint)
        }

        // 4. Glassy specular highlight
        val hx = cx - innerR * 0.30f
        val hy = cy - innerR * 0.35f
        val hlPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = RadialGradient(
                hx, hy, innerR * 0.45f,
                intArrayOf(0xAAFFFFFF.toInt(), 0),
                floatArrayOf(0f, 1f),
                Shader.TileMode.CLAMP
            )
        }
        canvas.drawCircle(hx, hy, innerR * 0.45f, hlPaint)

        canvas.restore()
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
        val r = minOf(w, h)
        val corner = r * 0.28f

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
    }
}

/**
 * Real Count camera overlay:
 *  - Idle State: glowing halo ring directly encircling the front camera punch-hole cutout
 *  - Active Social State: badge slides in beside the camera ring showing current app's Reel icon + total reels scrolled today
 *  - Drop Interaction: tapping camera halo smoothly unrolls a compact horizontal capsule strip (reference media_1794761463384_f466c5eb.png)
 *    Left target -> opens Snapy AI bottom sheet; Right target -> launches the social app.
 */
class ChipOverlay(
    private val ctx: Context,
    private val wm: WindowManager,
    private val windowType: Int,
    private val cb: Callbacks
) {
    interface Callbacks {
        fun onOpenSheet()
        fun onLaunchApp(pkg: String)
        fun onLongPress()
        fun onSwipeDown()
        fun onFullscreen(fullscreen: Boolean)
    }

    private val main = Handler(Looper.getMainLooper())
    private val prefs = RcPrefs(ctx)

    private var root: LinearLayout? = null
    private var cameraHalo: LivingOrbView? = null
    private var socialBadge: LinearLayout? = null
    private var badgeIcon: ReelIconView? = null
    private var badgeCountText: TextView? = null

    private var capsuleOverlay: View? = null
    private var stripTitleText: TextView? = null
    private var stripTimeText: TextView? = null
    private var stripReelText: TextView? = null
    private var stripReelIcon: ReelIconView? = null

    private var isSocialActive = false
    private var activeSocialPkg = "com.instagram.android"
    private var totalReels = 0
    private var screenTimeStr = "0m"

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
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            clipChildren = false
            clipToPadding = false
        }

        // 1. Camera Punch-Hole Halo Ring
        val halo = LivingOrbView(ctx).apply {
            layoutParams = LinearLayout.LayoutParams(dp(26f), dp(26f))
        }
        cameraHalo = halo
        r.addView(halo)

        // 2. Active Social Media Badge (slides beside camera)
        val badge = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            visibility = if (isSocialActive) View.VISIBLE else View.GONE
            setPadding(dp(6f), dp(2f), dp(8f), dp(2f))
            background = GradientDrawable().apply {
                cornerRadius = dp(11f).toFloat()
                setColor(0xEE161824.toInt())
                setStroke(dp(1f), 0x2EFFFFFF)
            }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                dp(22f)
            ).apply {
                leftMargin = dp(4f)
            }

            val icon = ReelIconView(ctx).apply {
                appPackage = activeSocialPkg
                layoutParams = LinearLayout.LayoutParams(dp(15f), dp(15f)).apply {
                    rightMargin = dp(4f)
                }
            }
            badgeIcon = icon
            addView(icon)

            val tv = TextView(ctx).apply {
                text = "$totalReels"
                setTextColor(0xFFFFFFFF.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f * scale)
                typeface = Typeface.create("sans-serif-bold", Typeface.BOLD)
                fontFeatureSettings = "tnum"
            }
            badgeCountText = tv
            addView(tv)
        }
        socialBadge = badge
        r.addView(badge)

        attachGestures(r)

        val p = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            dp(26f),
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

    data class CutoutData(val hasCutout: Boolean, val bounds: Rect, val cx: Int, val cy: Int, val size: Int)

    private fun getCutout(): CutoutData {
        val dm = ctx.resources.displayMetrics
        if (Build.VERSION.SDK_INT >= 30) {
            val insets = wm.currentWindowMetrics.windowInsets
            val cutout = insets.displayCutout
            if (cutout != null && cutout.boundingRects.isNotEmpty()) {
                val r = cutout.boundingRects[0]
                val sz = maxOf(r.width(), r.height())
                return CutoutData(true, r, r.centerX(), r.centerY(), sz)
            }
        } else if (Build.VERSION.SDK_INT >= 28) {
            @Suppress("DEPRECATION")
            val cutout = wm.defaultDisplay.cutout
            if (cutout != null && cutout.boundingRects.isNotEmpty()) {
                val r = cutout.boundingRects[0]
                val sz = maxOf(r.width(), r.height())
                return CutoutData(true, r, r.centerX(), r.centerY(), sz)
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

            val haloSize = if (cutout.hasCutout) {
                minOf(cutout.size, dp(34f)) + dp(6f) // bounded halo around punch-hole lens
            } else {
                dp(26f)
            }

            cameraHalo?.apply {
                if (cutout.hasCutout) {
                    isHaloRing = true
                    cutoutRadiusPx = minOf(cutout.size / 2f, dp(17f).toFloat())
                } else {
                    isHaloRing = false
                    cutoutRadiusPx = 0f
                }
                layoutParams = LinearLayout.LayoutParams(haloSize, haloSize)
            }

            p.x = (cutout.cx - haloSize / 2).coerceAtLeast(0)
            p.y = (cutout.cy - haloSize / 2).coerceAtLeast(0)
            p.width = WindowManager.LayoutParams.WRAP_CONTENT
            p.height = haloSize

            y = p.y
            height = p.height
            wm.updateViewLayout(r, p)
        } catch (_: Exception) { }
    }

    // ------------------------------------------------------------------ Social Badge
    fun setSocialActive(active: Boolean, pkg: String, reels: Int) = main.post {
        totalReels = reels
        if (pkg.isNotEmpty()) activeSocialPkg = pkg
        badgeIcon?.appPackage = activeSocialPkg
        stripReelIcon?.appPackage = activeSocialPkg

        if (isSocialActive == active) {
            badgeCountText?.text = "$totalReels"
            return@post
        }
        isSocialActive = active
        val badge = socialBadge ?: return@post
        val tv = badgeCountText ?: return@post

        if (active) {
            tv.text = "$totalReels"
            badge.visibility = View.VISIBLE
            badge.alpha = 0f
            badge.translationX = -dp(8f).toFloat()
            badge.animate()
                .alpha(1f)
                .translationX(0f)
                .setDuration(220)
                .setInterpolator(DecelerateInterpolator())
                .start()
        } else {
            badge.animate()
                .alpha(0f)
                .translationX(-dp(8f).toFloat())
                .setDuration(160)
                .withEndAction { badge.visibility = View.GONE }
                .start()
        }
    }

    fun onReelCounted(pkg: String, reels: Int) = main.post {
        totalReels = reels
        activeSocialPkg = pkg
        badgeIcon?.appPackage = pkg
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
        badgeCountText?.text = "$totalReels"
        stripTimeText?.text = "⏱ $screenTimeStr"
        stripReelText?.text = "$totalReels"
    }

    fun render(time: String, count: String, tone: ChipTone, ring: Float, desc: String) = main.post {
        screenTimeStr = time
        val rCount = count.filter { it.isDigit() }.toIntOrNull() ?: totalReels
        totalReels = rCount
        badgeCountText?.text = "$totalReels"
        stripTimeText?.text = "⏱ $screenTimeStr"
        stripReelText?.text = "$totalReels"
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
                }
            }
            .start()
    }

    private fun showCapsuleStrip() {
        dismissCapsuleStrip()
        val dm = ctx.resources.displayMetrics
        val capsuleW = minOf(dm.widthPixels - dp(24f), dp(320f))

        // Horizontal obsidian capsule matching media_1794761463384_f466c5eb.png
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

        // 1. Left Target: Snapy AI Section (Touch -> opens AI Bottom Sheet)
        val leftSection = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4f), dp(2f), dp(6f), dp(2f))
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

            // Title Text: "Real Count" or "+1 Reel"
            val titleTv = TextView(ctx).apply {
                text = "Real Count"
                setTextColor(0xFFFFFFFF.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f * scale)
                typeface = Typeface.create("sans-serif-bold", Typeface.BOLD)
                setPadding(dp(7f), 0, dp(4f), 0)
            }
            stripTitleText = titleTv
            addView(titleTv)

            setOnClickListener {
                dismissCapsuleStrip()
                cb.onOpenSheet()
            }
        }
        stripRoot.addView(leftSection)

        // 2. Middle: Divider & Screen Time
        val divider = View(ctx).apply {
            layoutParams = LinearLayout.LayoutParams(dp(1f), dp(16f)).apply {
                leftMargin = dp(4f)
                rightMargin = dp(8f)
            }
            setBackgroundColor(0x2AFFFFFF)
        }
        stripRoot.addView(divider)

        val timeTv = TextView(ctx).apply {
            text = "⏱ $screenTimeStr"
            setTextColor(0xFFB0B0B8.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f * scale)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            fontFeatureSettings = "tnum"
        }
        stripTimeText = timeTv
        stripRoot.addView(timeTv)

        val dotTv = TextView(ctx).apply {
            text = " · "
            setTextColor(0x55FFFFFF)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f * scale)
        }
        stripRoot.addView(dotTv)

        // 3. Right Target: Social App Launch (Touch -> launches Instagram / current app)
        val rightSection = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(6f), dp(2f), dp(4f), dp(2f))
            isClickable = true
            isFocusable = true
            background = GradientDrawable().apply {
                cornerRadius = dp(16f).toFloat()
                setColor(0x00000000)
            }

            // Official Reel Icon (Instagram sunset gradient or YouTube Shorts red)
            val reelIcon = ReelIconView(ctx).apply {
                appPackage = activeSocialPkg
                layoutParams = LinearLayout.LayoutParams(dp(19f), dp(19f))
            }
            stripReelIcon = reelIcon
            addView(reelIcon)

            // Total Reels Count
            val countTv = TextView(ctx).apply {
                text = "$totalReels"
                setTextColor(0xFFFFFFFF.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f * scale)
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
        val topY = if (cutout.hasCutout) cutout.bounds.bottom + dp(8f) else dp(44f)

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
                    if (!dragging && (abs(dx) > slop || abs(dy) > slop)) { dragging = true; main.removeCallbacks(longPress) }
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

/** Small cards under the chip: nudges, quick actions, intention prompt, today's breakdown. */
class OverlayCards(private val ctx: Context, private val wm: WindowManager, private val windowType: Int) {
    private val main = Handler(Looper.getMainLooper())
    private var card: View? = null
    private val dismiss = Runnable { remove() }

    private fun dp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, ctx.resources.displayMetrics).toInt()

    @SuppressLint("ClickableViewAccessibility")
    fun show(title: String?, body: String, actions: List<Pair<String, String>>, belowY: Int, timeoutMs: Long,
             bigText: Boolean = false, onAction: (String) -> Unit) = main.post {
        remove()
        val textSize = if (bigText) 17f else 14f
        val box = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16f), dp(12f), dp(16f), dp(10f))
            background = GradientDrawable().apply { cornerRadius = dp(18f).toFloat(); setColor(0xF0111114.toInt()); setStroke(1, 0x33FFFFFF) }
        }
        if (!title.isNullOrEmpty()) box.addView(TextView(ctx).apply {
            text = title; setTextColor(0xFFF5F5F7.toInt()); setTextSize(TypedValue.COMPLEX_UNIT_SP, textSize + 1)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        })
        box.addView(TextView(ctx).apply {
            text = body; setTextColor(0xFFF5F5F7.toInt()); setTextSize(TypedValue.COMPLEX_UNIT_SP, textSize)
            setLineSpacing(0f, 1.15f)
        })
        if (actions.isNotEmpty()) {
            val row = LinearLayout(ctx).apply {
                orientation = if (actions.size > 2 || bigText) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
                gravity = Gravity.END
                setPadding(0, dp(6f), 0, 0)
            }
            actions.forEachIndexed { i, (id, label) ->
                row.addView(Button(ctx, null, android.R.attr.borderlessButtonStyle).apply {
                    text = label
                    isAllCaps = false
                    setTextColor(if (i == 0) 0xFF0A84FF.toInt() else 0xFFA1A1A6.toInt())
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, textSize)
                    setOnClickListener { remove(); onAction(id) }
                })
            }
            box.addView(row)
        }
        box.setOnTouchListener { _, e ->
            if (e.actionMasked == MotionEvent.ACTION_OUTSIDE) { remove(); onAction("dismiss") }
            false
        }
        val lp = WindowManager.LayoutParams(
            (ctx.resources.displayMetrics.widthPixels * 0.92).toInt(), WindowManager.LayoutParams.WRAP_CONTENT, windowType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH,
            PixelFormat.TRANSLUCENT,
        ).apply { gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL; y = belowY + dp(8f) }
        try { wm.addView(box, lp); card = box } catch (_: Exception) { return@post }
        if (timeoutMs > 0) main.postDelayed(dismiss, timeoutMs)
    }

    fun remove() {
        main.removeCallbacks(dismiss)
        card?.let { try { wm.removeView(it) } catch (_: Exception) { } }
        card = null
    }
}
