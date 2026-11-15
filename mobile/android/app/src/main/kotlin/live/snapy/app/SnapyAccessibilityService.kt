package live.snapy.app

import android.accessibilityservice.AccessibilityService
import android.animation.ValueAnimator
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
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
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.animation.AccelerateInterpolator
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
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

    private var socialApps = mapOf(
        "com.instagram.android" to JSONObject().put("label", "Instagram").put("short_video", "Reels"),
        "com.google.android.youtube" to JSONObject().put("label", "YouTube").put("short_video", "Shorts"),
        "com.snapchat.android" to JSONObject().put("label", "Snapchat").put("short_video", "Spotlight"),
        "com.facebook.katana" to JSONObject().put("label", "Facebook").put("short_video", "Reels"),
        "com.facebook.lite" to JSONObject().put("label", "Facebook Lite").put("short_video", "Reels"),
        "com.zhiliaoapp.musically" to JSONObject().put("label", "TikTok").put("short_video", "Videos"),
        "com.ss.android.ugc.trill" to JSONObject().put("label", "TikTok").put("short_video", "Videos"),
        "com.twitter.android" to JSONObject().put("label", "X").put("short_video", null),
        "com.reddit.frontpage" to JSONObject().put("label", "Reddit").put("short_video", null),
        "com.whatsapp" to JSONObject().put("label", "WhatsApp").put("short_video", null),
        "in.mohalla.video" to JSONObject().put("label", "Moj").put("short_video", "Videos"),
        "com.eterno.shortvideos" to JSONObject().put("label", "Josh").put("short_video", "Videos")
    )
    private var minDwellMs = 700L
    private var refreshMs = 60_000L
    private var viewTypes = JSONObject()                 // Android class -> matcher type (app.json)
    private var lastNodes = listOf<AccessibilityNodeInfo>()

    private var currentPkg = ""
    private var lastReelAt = HashMap<String, Long>()
    private var lastIndex = HashMap<String, Int>()
    private var reelTimeFrom = 0L
    private var todayMs = 0L
    private var appMs = mapOf<String, Long>()

    /** Camera Punch-Hole Halo Ring & Dropped Capsule Strip (RealCountController). */
    private var rc: RealCountController? = null

    override fun onServiceConnected() {
        instance = this
        wm = getSystemService(WINDOW_SERVICE) as WindowManager
        store = RealCountStore(this)
        usage = UsageTracker(this)
        loadConfig()
        ChipService.stop(this)                           // the counter's own chip replaces the fallback one
        rc = RealCountController(this, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY, counting = true,
            externalCounter = true, showChip = true).also { it.start() }
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

    // ------------------------------------------------------------------ hardware shortcuts
    private var volUpTime = 0L
    private var volDownTime = 0L

    override fun onKeyEvent(event: android.view.KeyEvent): Boolean {
        val now = System.currentTimeMillis()
        if (event.keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP) {
            if (event.action == android.view.KeyEvent.ACTION_DOWN) {
                if (volUpTime == 0L) volUpTime = now
            } else if (event.action == android.view.KeyEvent.ACTION_UP) {
                volUpTime = 0L
            }
        } else if (event.keyCode == android.view.KeyEvent.KEYCODE_VOLUME_DOWN) {
            if (event.action == android.view.KeyEvent.ACTION_DOWN) {
                if (volDownTime == 0L) volDownTime = now
            } else if (event.action == android.view.KeyEvent.ACTION_UP) {
                volDownTime = 0L
            }
        }
        if (volUpTime > 0L && volDownTime > 0L && (now - minOf(volUpTime, volDownTime) >= 2400L)) {
            volUpTime = 0L
            volDownTime = 0L
            openSheet()
            return true
        }
        return super.onKeyEvent(event)
    }

    // ------------------------------------------------------------------ events
    override fun onAccessibilityEvent(e: AccessibilityEvent) {
        val pkg = e.packageName?.toString() ?: return
        if (pkg == packageName) return // never intercept or count events inside Snapy itself
        when (e.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> { onWindow(pkg); rc?.onWindow(pkg, e.className?.toString() ?: "") }
            AccessibilityEvent.TYPE_VIEW_SCROLLED -> if (pkg == currentPkg) { rc?.onScrollEvent(pkg); onScroll(pkg, e) }
        }
    }

    fun showPillPublic() = main.post { rc?.reload() }

    private fun onWindow(pkg: String) {
        if (pkg == currentPkg || pkg == packageName || pkg == "com.android.systemui") return
        flushReelTime()
        currentPkg = pkg
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
        if (rc?.shouldCount(pkg, src?.viewIdResourceName ?: "") == false) return   // creator mode / paused counting
        lastReelAt[pkg] = now
        if (reelTimeFrom == 0L) reelTimeFrom = now
        store.addReel(pkg)
        rc?.onReelCounted()

        // Check per-app reel limit and lock if reached
        val prefs = RcPrefs(this)
        val limit = prefs.int("limit_$pkg", prefs.int("reel_limit", 100))
        val lockEnabled = prefs.bool("lock_$pkg", true)
        val currentReels = store.reels(pkg)
        if (lockEnabled && limit > 0 && currentReels >= limit) {
            performGlobalAction(GLOBAL_ACTION_BACK)
            val label = app.optString("label", pkg)
            main.post {
                Toast.makeText(this@SnapyAccessibilityService, "🚫 $label reels locked for today ($currentReels/$limit reached). Stay focused!", Toast.LENGTH_LONG).show()
            }
        }
    }

    /** Time inside short-video feeds: from the first reel until leaving the app (idle gaps capped). */
    private fun flushReelTime() {
        if (reelTimeFrom == 0L || currentPkg.isEmpty()) return
        val end = (lastReelAt[currentPkg] ?: reelTimeFrom) + 60_000            // up to 1 min on the last reel
        store.addReelTime(currentPkg, (minOf(end, System.currentTimeMillis()) - reelTimeFrom).coerceAtLeast(0))
        reelTimeFrom = 0L
        store.save()
    }

    private fun tick() {
        Thread {
            try {
                val t = usage.today()
                todayMs = t.totalMs
                appMs = t.perApp
            } catch (_: Throwable) {}
        }.start()
        main.postDelayed({ tick() }, refreshMs)
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
        rc?.onVoice(state, text)
    }

    /** Today's numbers for the app/dashboard and the AI. */
    fun todayJson(): JSONObject = try {
        store.today().put("screen_ms", todayMs).put("current", currentPkg)
    } catch (_: Throwable) {
        JSONObject().put("screen_ms", 0L).put("reels", JSONObject()).put("current", "")
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        flushReelTime()
        rc?.stop()
        rc = null
        instance = null
        ChipService.startIfWanted(applicationContext)    // keep a chip via "Display over other apps" if allowed
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
