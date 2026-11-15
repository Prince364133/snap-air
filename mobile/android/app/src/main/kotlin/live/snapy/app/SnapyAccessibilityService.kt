package live.snapy.app

import android.accessibilityservice.AccessibilityService
import android.content.Context
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
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
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
    private var viewTypes = JSONObject()                 // Android class -> matcher type (app.json)
    private var lastNodes = listOf<AccessibilityNodeInfo>()

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
                viewTypes = JSONObject(core.configNow("android.view_types"))
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
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT, h,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        )
        if (Build.VERSION.SDK_INT >= 30) lp.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        placeBesideCamera(lp, h)

        var initialX = 0
        var initialY = 0
        var initialTouchX = 0f
        var initialTouchY = 0f
        var isDragging = false
        var downTime = 0L

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
            contentDescription = "Snapy Real Count — drag to reposition, tap to talk to Snapy"

            setOnTouchListener { _, event ->
                when (event.action) {
                    MotionEvent.ACTION_DOWN -> {
                        initialX = lp.x
                        initialY = lp.y
                        initialTouchX = event.rawX
                        initialTouchY = event.rawY
                        isDragging = false
                        downTime = System.currentTimeMillis()
                        true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        val dx = (event.rawX - initialTouchX).toInt()
                        val dy = (event.rawY - initialTouchY).toInt()
                        if (!isDragging && (abs(dx) > dp(5f) || abs(dy) > dp(5f))) {
                            isDragging = true
                        }
                        if (isDragging) {
                            val screenW = resources.displayMetrics.widthPixels
                            val screenH = resources.displayMetrics.heightPixels
                            lp.x = (initialX + dx).coerceIn(0, screenW - dp(80f))
                            lp.y = (initialY + dy).coerceIn(0, screenH - h)
                            try { wm.updateViewLayout(this, lp) } catch (_: Exception) {}
                        }
                        true
                    }
                    MotionEvent.ACTION_UP -> {
                        val elapsed = System.currentTimeMillis() - downTime
                        if (!isDragging) {
                            if (elapsed >= 3000) {
                                // 3-second hold: shut off / snooze for 1 hour
                                hiddenUntil = System.currentTimeMillis() + 3600_000
                                updatePill()
                            } else {
                                // Simple tap: open assistant
                                openSheet()
                            }
                        } else {
                            // Remember position where user dragged it
                            getSharedPreferences("snapy_pill", Context.MODE_PRIVATE).edit()
                                .putInt("pill_x", lp.x)
                                .putInt("pill_y", lp.y)
                                .apply()
                        }
                        true
                    }
                    else -> false
                }
            }
        }
        wm.addView(p, lp)
        pill = p
        updatePill()
    }

    /** Sit in the status-bar row or user's custom saved position. Defaults safely on the right side. */
    private fun placeBesideCamera(lp: WindowManager.LayoutParams, h: Int) {
        lp.gravity = Gravity.TOP or Gravity.START
        val width = resources.displayMetrics.widthPixels
        val prefs = getSharedPreferences("snapy_pill", Context.MODE_PRIVATE)
        if (prefs.contains("pill_x") && prefs.contains("pill_y")) {
            lp.x = prefs.getInt("pill_x", 0).coerceIn(0, width - dp(80f))
            lp.y = prefs.getInt("pill_y", 0).coerceIn(0, resources.displayMetrics.heightPixels - h)
            return
        }

        var y = dp(4f)
        if (Build.VERSION.SDK_INT >= 30) {
            val insets = wm.currentWindowMetrics.windowInsets
            val bar = insets.getInsets(WindowInsets.Type.statusBars()).top
            if (bar > 0) y = ((bar - h) / 2).coerceAtLeast(0)
        }
        // Place on the top right side to guarantee it never collides with center Dynamic Islands / hotspot capsules
        lp.x = (width - dp(145f)).coerceAtLeast(dp(10f))
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

    // ------------------------------------------------------------------ screen actions (Phase 4)
    /** Visible, named, actionable nodes of the app on screen, in the same shape as the Windows
     *  UI Automation snapshot, so the shared screen.find() can choose one. */
    fun snapshotNodes(): JSONArray {
        val out = JSONArray()
        val keep = ArrayList<AccessibilityNodeInfo>()
        val root = rootInActiveWindow ?: return out
        if (root.packageName == packageName) return out             // never act on Snapy itself
        fun walk(n: AccessibilityNodeInfo?, depth: Int) {
            if (n == null || keep.size >= 300 || depth > 40) return
            if (n.isVisibleToUser) {
                val name = (n.text ?: n.contentDescription ?: "").toString().trim()
                val cls = n.className?.toString()?.substringAfterLast('.') ?: ""
                val actionable = n.isClickable || n.isEditable || n.isCheckable
                if (actionable && (name.isNotEmpty() || n.isEditable)) {
                    val type = viewTypes.optString(cls, "").ifEmpty {
                        if (n.isEditable) "EditControl" else if (n.childCount > 0) viewTypes.optString("_clickable_group", "ListItemControl") else "ButtonControl"
                    }
                    // a clickable card often has no text itself: name it from its children (video titles)
                    val label = name.ifEmpty { childText(n) }.ifEmpty { if (n.isEditable) "text field" else "" }
                    if (label.isNotEmpty()) {
                        val r = Rect(); n.getBoundsInScreen(r)
                        if (r.width() > 4 && r.height() > 4) {
                            out.put(JSONObject().put("name", label.take(160)).put("type", type)
                                .put("rect", JSONArray(listOf(r.left, r.top, r.right, r.bottom))).put("depth", depth))
                            keep.add(n)
                        }
                    }
                }
            }
            for (i in 0 until n.childCount) walk(n.getChild(i), depth + 1)
        }
        walk(root, 0)
        lastNodes = keep
        return out
    }

    private fun childText(n: AccessibilityNodeInfo, max: Int = 3): String {
        val parts = ArrayList<String>()
        fun go(c: AccessibilityNodeInfo?, d: Int) {
            if (c == null || d > 6 || parts.size >= max) return
            val t = (c.text ?: c.contentDescription ?: "").toString().trim()
            if (t.isNotEmpty()) parts.add(t)
            for (i in 0 until c.childCount) go(c.getChild(i), d + 1)
        }
        for (i in 0 until n.childCount) go(n.getChild(i), 1)
        return parts.joinToString(" · ")
    }

    fun clickNode(i: Int): Boolean {
        var n: AccessibilityNodeInfo? = lastNodes.getOrNull(i) ?: return false
        while (n != null && !n.isClickable) n = n.parent
        return n?.performAction(AccessibilityNodeInfo.ACTION_CLICK) ?: false
    }

    fun typeIntoFocused(text: String): Boolean {
        val f = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        if (!f.isEditable) return false
        val existing = f.text?.toString().orEmpty().let { if (f.isShowingHintText) "" else it }
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, if (existing.isEmpty()) text else "$existing $text")
        }
        return f.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    /** Fixed script step: wait (up to timeout) for a known button (view ID or description) and tap it once. */
    fun tapWhenVisible(selectors: JSONArray, timeoutMs: Long) {
        val until = System.currentTimeMillis() + timeoutMs
        fun attempt() {
            val root = rootInActiveWindow
            if (root != null) {
                for (i in 0 until selectors.length()) {
                    val sel = selectors.getString(i)
                    val hits = if (sel.contains(":id/")) root.findAccessibilityNodeInfosByViewId(sel)
                               else root.findAccessibilityNodeInfosByText(sel).filter { it.contentDescription?.toString() == sel }
                    val target = hits.firstOrNull { it.isVisibleToUser && it.isEnabled }
                    if (target != null) {
                        var n: AccessibilityNodeInfo? = target
                        while (n != null && !n.isClickable) n = n.parent
                        if (n?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true) return
                    }
                }
            }
            if (System.currentTimeMillis() < until) main.postDelayed({ attempt() }, 400)
        }
        main.postDelayed({ attempt() }, 900)
    }

    /** Voice feedback in the pill (wake word or push-to-talk while another app is open). */
    fun showVoice(state: String, text: String) = main.post {
        val p = pill ?: return@post
        p.visibility = View.VISIBLE
        when (state) {
            "listening" -> pillText?.text = if (text.isBlank()) "Listening…" else text.takeLast(28)
            "partial" -> pillText?.text = text.takeLast(28)
            "thinking" -> pillText?.text = "Thinking…"
            else -> updatePill()
        }
        if (state == "thinking") main.postDelayed({ updatePill() }, 6000)
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
