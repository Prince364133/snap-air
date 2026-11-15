package live.snapy.app

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs

/**
 * Real Count.
 *  - Shows the Snapy pill in the status-bar row, beside the camera cut-out, over every app.
 *  - Counts reels/shorts: a full-screen vertical page change in a short-video app, kept on
 *    screen at least `android.min_reel_dwell_ms` (quick flicks don't count).
 *  - Greets you when you open a social app with today's numbers.
 *  - Performs Back / Home / Recents / Notifications / Lock / Screenshot for voice commands.
 * Everything is deterministic, rule-based and on-device (Google Play accessibility policy).
 */
class SnapyAccessibilityService : AccessibilityService() {
    private lateinit var wm: WindowManager
    private lateinit var store: RealCountStore
    private lateinit var usage: UsageTracker
    private val main = Handler(Looper.getMainLooper())

    private var pill: LinearLayout? = null
    private var pillText: TextView? = null
    private var card: View? = null

    private var socialApps = mapOf<String, JSONObject>()        // package -> {label, short_video}
    private var minDwellMs = 700L
    private var refreshMs = 60_000L

    private var currentPkg = ""
    private var lastReelAt = HashMap<String, Long>()
    private var lastIndex = HashMap<String, Int>()
    private var reelTimeFrom = 0L
    private var lastNudge = HashMap<String, Long>()
    private var todayMs = 0L
    private var appMs = mapOf<String, Long>()
    private var hiddenUntil = 0L

    override fun onServiceConnected() {
        instance = this
        wm = getSystemService(WINDOW_SERVICE) as WindowManager
        store = RealCountStore(this)
        usage = UsageTracker(this)
        loadConfig()
        showPill()
        tick()
    }

    /** Social apps and thresholds come from the shared app.json (no hardcoding). */
    private fun loadConfig() {
        Thread {
            try {
                val core = CoreBridge.get(this)
                val apps = JSONArray(core.configNow("android.social_apps"))
                val m = HashMap<String, JSONObject>()
                for (i in 0 until apps.length()) apps.getJSONObject(i).let { m[it.getString("package")] = it }
                socialApps = m
                minDwellMs = core.configNow("android.min_reel_dwell_ms").toLongOrNull() ?: minDwellMs
                refreshMs = (core.configNow("android.screen_time_refresh_s").toLongOrNull() ?: 60) * 1000
            } catch (_: Exception) { }
        }.start()
    }

    // ------------------------------------------------------------------ events
    override fun onAccessibilityEvent(e: AccessibilityEvent) {
        val pkg = e.packageName?.toString() ?: return
        when (e.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> onWindow(pkg)
            AccessibilityEvent.TYPE_VIEW_SCROLLED -> if (pkg == currentPkg) onScroll(pkg, e)
        }
    }

    private fun onWindow(pkg: String) {
        if (pkg == currentPkg || pkg == packageName || pkg == "com.android.systemui") return
        flushReelTime()
        val prev = currentPkg
        currentPkg = pkg
        if (socialApps.containsKey(pkg) && pkg != prev) nudge(pkg)
        updatePill()
    }

    private fun onScroll(pkg: String, e: AccessibilityEvent) {
        val app = socialApps[pkg] ?: return
        if (app.isNull("short_video")) return
        val screenH = resources.displayMetrics.heightPixels
        // only full-screen vertical feeds (the reels/shorts pager), not comment lists or tabs
        val src = e.source
        if (src != null) {
            val r = Rect()
            src.getBoundsInScreen(r)
            if (r.height() < screenH * 0.6) return
        }
        val now = System.currentTimeMillis()
        val pageChanged = when {
            e.fromIndex >= 0 && e.toIndex >= 0 && e.itemCount > 1 -> {
                val prev = lastIndex[pkg]
                lastIndex[pkg] = e.fromIndex
                prev != null && prev != e.fromIndex
            }
            Build.VERSION.SDK_INT >= 28 -> abs(e.scrollDeltaY) >= screenH * 0.5
            else -> false
        }
        if (!pageChanged) return
        val last = lastReelAt[pkg] ?: 0L
        if (now - last < minDwellMs) return                      // a flick past, not a watch
        lastReelAt[pkg] = now
        if (reelTimeFrom == 0L) reelTimeFrom = now
        store.addReel(pkg)
        updatePill()
    }

    /** Time inside short-video feeds: from the first reel until leaving the app (idle gaps capped). */
    private fun flushReelTime() {
        if (reelTimeFrom == 0L || currentPkg.isEmpty()) return
        val end = (lastReelAt[currentPkg] ?: reelTimeFrom) + 60_000            // up to 1 min on the last reel
        store.addReelTime(currentPkg, (minOf(end, System.currentTimeMillis()) - reelTimeFrom).coerceAtLeast(0))
        reelTimeFrom = 0L
        store.save()
    }

    // ------------------------------------------------------------------ pill
    private fun dp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics).toInt()

    private fun orb(size: Int) = View(this).apply {
        background = GradientDrawable(GradientDrawable.Orientation.TL_BR,
            intArrayOf(0xFFFFFFFF.toInt(), 0xFF5E81FF.toInt(), 0xFF966EFF.toInt(), 0xFF46C8FF.toInt())).apply {
            shape = GradientDrawable.OVAL
            gradientType = GradientDrawable.RADIAL_GRADIENT
            gradientRadius = size * 0.75f
            setGradientCenter(0.35f, 0.3f)
        }
        layoutParams = LinearLayout.LayoutParams(size, size)
    }

    private fun showPill() {
        if (pill != null) return
        val h = dp(26f)
        val p = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(3f), 0, dp(10f), 0)
            background = GradientDrawable().apply { cornerRadius = h / 2f; setColor(0xE6111114.toInt()); setStroke(1, 0x33FFFFFF) }
            addView(orb(dp(20f)))
            pillText = TextView(this@SnapyAccessibilityService).apply {
                setTextColor(0xFFF5F5F7.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                setPadding(dp(6f), 0, 0, 0)
                fontFeatureSettings = "tnum"
            }
            addView(pillText)
            setOnClickListener { openSheet() }
            setOnLongClickListener { hiddenUntil = System.currentTimeMillis() + 3600_000; updatePill(); true }
            contentDescription = "Snapy Real Count — tap to talk to Snapy"
        }
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT, h,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        )
        if (Build.VERSION.SDK_INT >= 30) lp.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        placeBesideCamera(lp, h)
        wm.addView(p, lp)
        pill = p
        updatePill()
    }

    /** Sit in the status-bar row: right of a centred punch-hole, beside a corner one, else top-centre. */
    private fun placeBesideCamera(lp: WindowManager.LayoutParams, h: Int) {
        lp.gravity = Gravity.TOP or Gravity.START
        val width = resources.displayMetrics.widthPixels
        var y = dp(4f)
        var x = width / 2 - dp(56f)
        if (Build.VERSION.SDK_INT >= 30) {
            val insets = wm.currentWindowMetrics.windowInsets
            val cut = insets.displayCutout
            val bar = insets.getInsets(WindowInsets.Type.statusBars()).top
            if (bar > 0) y = ((bar - h) / 2).coerceAtLeast(0)
            val r = cut?.boundingRects?.firstOrNull { it.top < bar + dp(8f) }
            if (r != null) {
                y = (r.centerY() - h / 2).coerceAtLeast(0)
                x = if (r.centerX() > width * 0.3 && r.centerX() < width * 0.7) r.right + dp(8f)   // centred hole
                else if (r.centerX() <= width * 0.3) r.right + dp(8f)                               // left corner
                else r.left - dp(130f)                                                              // right corner
            }
        }
        lp.x = x.coerceIn(0, width - dp(130f))
        lp.y = y
    }

    private fun updatePill() = main.post {
        val p = pill ?: return@post
        if (System.currentTimeMillis() < hiddenUntil) { p.visibility = View.GONE; return@post }
        p.visibility = View.VISIBLE
        val app = socialApps[currentPkg]
        pillText?.text = if (app != null && !app.isNull("short_video")) {
            val n = store.reels(currentPkg)
            "▶ $n · ${UsageTracker.format(appMs[currentPkg] ?: 0)}"
        } else {
            "⏱ ${UsageTracker.format(todayMs)}"
        }
    }

    private fun tick() {
        Thread {
            val t = usage.today()
            todayMs = t.totalMs
            appMs = t.perApp
            updatePill()
        }.start()
        main.postDelayed({ tick() }, refreshMs)
    }

    // ------------------------------------------------------------------ nudge card
    private fun nudge(pkg: String) {
        val now = System.currentTimeMillis()
        if (now - (lastNudge[pkg] ?: 0L) < 30 * 60_000) return
        lastNudge[pkg] = now
        val app = socialApps[pkg] ?: return
        val label = app.optString("label", "This app")
        val kind = app.optString("short_video", "")
        val reels = store.reels(pkg)
        val mins = UsageTracker.format(appMs[pkg] ?: 0)
        val text = if (kind.isNotEmpty() && kind != "null")
            "$label · $reels ${kind.lowercase()} · $mins today" else "$label · $mins today"
        main.post { showCard(text) }
    }

    private fun showCard(text: String) {
        card?.let { try { wm.removeView(it) } catch (_: Exception) { } }
        val v = TextView(this).apply {
            this.text = text
            setTextColor(0xFFF5F5F7.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setPadding(dp(16f), dp(10f), dp(16f), dp(10f))
            background = GradientDrawable().apply { cornerRadius = dp(18f).toFloat(); setColor(0xF0111114.toInt()); setStroke(1, 0x33FFFFFF) }
            setOnClickListener { openSheet(); removeCard() }
        }
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply { gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL; y = dp(44f) }
        wm.addView(v, lp)
        card = v
        main.postDelayed({ removeCard() }, 4500)
    }

    private fun removeCard() {
        card?.let { try { wm.removeView(it) } catch (_: Exception) { } }
        card = null
    }

    private fun openSheet() {
        startActivity(Intent(this, SheetActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    /** Today's numbers for the app/dashboard and the AI. */
    fun todayJson(): JSONObject = store.today().put("screen_ms", todayMs).put("current", currentPkg)

    override fun onInterrupt() {}

    override fun onDestroy() {
        flushReelTime()
        pill?.let { try { wm.removeView(it) } catch (_: Exception) { } }
        removeCard()
        instance = null
        super.onDestroy()
    }

    companion object {
        @Volatile var instance: SnapyAccessibilityService? = null

        /** Voice commands: back / home / recents / notifications / quick_settings / lock / screenshot. */
        fun global(action: String): Boolean {
            val s = instance ?: return false
            val a = when (action) {
                "back" -> GLOBAL_ACTION_BACK
                "home" -> GLOBAL_ACTION_HOME
                "recents" -> GLOBAL_ACTION_RECENTS
                "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
                "quick_settings" -> GLOBAL_ACTION_QUICK_SETTINGS
                "lock" -> GLOBAL_ACTION_LOCK_SCREEN
                "screenshot" -> GLOBAL_ACTION_TAKE_SCREENSHOT
                else -> return false
            }
            return s.performGlobalAction(a)
        }
    }
}
