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
 *  - Forwards scroll events to THE reel counter (RealCountController -> ReelCounter, mirror of
 *    lib/realcount/reel_counter.dart): catalogue short-video apps only, full-screen pager,
 *    page change (ViewPager2-safe), min dwell. It never counts by itself.
 *  - Hard lock (opt-in per app): ReelLockController bounces ONLY the short-video feed (Back).
 *  - Volume Up+Down / accessibility button -> Activation (no key filtering).
 *  - Greets you when you open a social app with today's numbers.
 *  - Performs Back / Home / Recents / Notifications / Lock / Screenshot for voice commands.
 * Everything is deterministic, rule-based and on-device (Google Play accessibility policy).
 */
class SnapyAccessibilityService : AccessibilityService() {
    private lateinit var wm: WindowManager
    private lateinit var store: RealCountStore
    private lateinit var usage: UsageTracker
    private val main = Handler(Looper.getMainLooper())

    /** The catalogue (core rules android.social_apps): no package-name guessing. */
    @Volatile private var socialApps = mapOf<String, JSONObject>()
    @Volatile private var longVideoApps = setOf<String>()
    private var refreshMs = 60_000L
    private var viewTypes = JSONObject()                 // Android class -> matcher type (app.json)
    private var lastNodes = listOf<AccessibilityNodeInfo>()

    private var currentPkg = ""
    private var todayMs = 0L
    private var appMs = mapOf<String, Long>()
    private val timeNoticeDay = HashMap<String, String>()

    /** Camera Punch-Hole Halo Ring & Dropped Capsule Strip + THE reel counter (RealCountController). */
    private var rc: RealCountController? = null
    /** Hard lock / deflector (ReelLockController). */
    private var lock: ReelLockController? = null
    private var buttonCallback: Any? = null

    /**
     * Every step is guarded on its own: an exception here used to crash the process, and Android
     * then leaves a crashed accessibility service unbound (shown as OFF on ColorOS) until the user
     * re-enables it. A failing step is recorded (CrashLog) and the rest still starts.
     */
    override fun onServiceConnected() {
        instance = this
        wm = getSystemService(WINDOW_SERVICE) as WindowManager
        store = RealCountStore(this)
        usage = UsageTracker(this)
        safe("prefs") { RcPrefs(this).putLong(A11yHealth.PREF_CONNECTED_AT, System.currentTimeMillis()) }
        safe("config") { loadConfig() }
        safe("chip_service") { ChipService.stop(this) }      // the counter's own chip replaces the fallback one
        safe("reel_lock") { lock = ReelLockController(this).also { ReelLockController.active = it } }
        // ONE counting path: the controller counts (ReelCounter); this service only forwards events
        safe("counter") {
            rc = RealCountController(this, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY, counting = true,
                externalCounter = false, showChip = true).also { it.start() }
        }
        safe("shortcut") { registerShortcut() }
        safe("tick") { tick() }
        safe("wake") { WakeWordService.ensureRunning(this) }   // the phone killed Snapy: "Hey Snapy" back too
    }

    private inline fun safe(step: String, block: () -> Unit) {
        try { block() } catch (t: Throwable) {
            if (t is VirtualMachineError) throw t
            CrashLog.record(this, "a11y.$step", t)
        }
    }

    /**
     * Volume Up + Down (held) and the accessibility button -> Activation.trigger.
     * Snapy is the target of Android's accessibility shortcut; because this service declares
     * flagRequestAccessibilityButton and targets Android 11+, AOSP
     * (AccessibilityManagerService.performAccessibilityShortcutTargetService) calls this
     * callback instead of toggling the service off ("Held volume keys… turned off" no longer
     * happens), and turns the service on if it was off. No key-event filtering (ColorOS kills
     * services that filter keys).
     */
    private fun registerShortcut() {
        try {
            val cb = object : android.accessibilityservice.AccessibilityButtonController.AccessibilityButtonCallback() {
                override fun onClicked(controller: android.accessibilityservice.AccessibilityButtonController) {
                    Activation.trigger(this@SnapyAccessibilityService, "volume")
                }
            }
            accessibilityButtonController.registerAccessibilityButtonCallback(cb, main)
            buttonCallback = cb
        } catch (_: Throwable) { }
    }

    /** Social apps and thresholds come from the shared core rules (no hardcoding). */
    private fun loadConfig() {
        Thread {
            try {
                val apps = CoreConfig.value(this, "android.social_apps") as? JSONArray ?: JSONArray()
                val m = HashMap<String, JSONObject>()
                for (i in 0 until apps.length()) apps.optJSONObject(i)?.let { m[it.optString("package")] = it }
                socialApps = m
                // long-video watching is tracked in the apps the rules name (else: every catalogue
                // short-video app; only YouTube-style players produce 35 s+ watches)
                val lv = CoreConfig.value(this, "android.realcount.long_video_apps") as? JSONArray
                longVideoApps = if (lv != null) (0 until lv.length()).map { lv.optString(it) }.toSet()
                                else m.filterValues { !it.isNull("short_video") }.keys
                refreshMs = ((CoreConfig.value(this, "android.screen_time_refresh_s") as? Number)?.toLong() ?: 60) * 1000
                viewTypes = CoreConfig.value(this, "android.view_types") as? JSONObject ?: JSONObject()
            } catch (_: Exception) { }
        }.start()
    }

    // ------------------------------------------------------------------ hardware shortcuts
    /** Only reached on builds where key filtering is allowed (canRequestFilterKeyEvents=true);
     *  the shipped config keeps it off. Consumes only the Volume Up+Down combo. */
    private val combo = VolumeCombo()
    private val comboFire = Runnable { if (combo.poll(android.os.SystemClock.uptimeMillis())) Activation.trigger(this, "volume") }

    override fun onKeyEvent(event: android.view.KeyEvent): Boolean {
        val up = event.keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP
        if (!up && event.keyCode != android.view.KeyEvent.KEYCODE_VOLUME_DOWN) return false   // never other keys
        if (!Activation.modeOn(this, "volume")) return false
        val down = event.action == android.view.KeyEvent.ACTION_DOWN
        val consume = combo.onKey(up = up, down = down, t = event.eventTime)
        main.removeCallbacks(comboFire)
        combo.fireAt?.let { at -> main.postAtTime(comboFire, at) }
        return consume
    }

    // ------------------------------------------------------------------ events
    private var currentVideoStart = 0L
    private var currentVideoPkg = ""
    private var videoCountedForSession = false

    private fun checkLongVideoProgress(pkg: String, e: AccessibilityEvent) {
        if (pkg !in longVideoApps) return
        val now = System.currentTimeMillis()
        if (pkg != currentVideoPkg) {
            currentVideoPkg = pkg
            currentVideoStart = now
            videoCountedForSession = false
            return
        }
        if (e.eventType == AccessibilityEvent.TYPE_VIEW_CLICKED) {          // a tap on a video starts a new watch
            currentVideoStart = now
            videoCountedForSession = false
        }
        // a long video: watched 35 s+ with no reel counted meanwhile
        if (!videoCountedForSession && currentVideoStart > 0L && (now - currentVideoStart) >= 35_000L) {
            if (now - (rc?.lastReelAt(pkg) ?: 0L) >= 30_000L) {
                videoCountedForSession = true
                store.addLongVideo(pkg)
            }
        }
    }

    /** Never throws: a bad event (an app's odd node tree) must not kill the service. */
    override fun onAccessibilityEvent(e: AccessibilityEvent) = safe("event") { handleEvent(e) }

    private fun handleEvent(e: AccessibilityEvent) {
        val pkg = e.packageName?.toString() ?: return
        if (pkg == packageName) return // never intercept or count events inside Snapy itself
        when (e.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                onWindow(pkg)
                rc?.onWindow(pkg, e.className?.toString() ?: "")
                lock?.onWindow(pkg)
            }
            AccessibilityEvent.TYPE_VIEW_SCROLLED -> if (pkg == currentPkg) {
                lock?.onScroll(pkg, e)                                      // bounce first: the 150 ms budget
                forwardScroll(pkg, e)
            }
            AccessibilityEvent.TYPE_VIEW_CLICKED -> lock?.onClick(pkg)
        }
        // after onWindow: an app switch has already credited the previous long video
        checkLongVideoProgress(pkg, e)
    }

    /** The scroll, measured, to the one counter (RealCountController -> ReelCounter). */
    private fun forwardScroll(pkg: String, e: AccessibilityEvent) {
        val app = socialApps[pkg]
        val shortVideo = app != null && !app.isNull("short_video")
        rc?.onScrollEvent(pkg)
        if (!shortVideo) return
        val src = e.source
        val dm = resources.displayMetrics
        val r = Rect()
        src?.getBoundsInScreen(r)
        val key = if (src != null && e.fromIndex < 0) ReelCounter.itemKey(src, dm.widthPixels, dm.heightPixels) else ""
        rc?.onScroll(ReelScroll(
            pkg = pkg,
            shortVideoApp = true,
            heightFraction = if (src != null) r.height().toDouble() / dm.heightPixels else 0.0,
            widthFraction = if (src != null) r.width().toDouble() / dm.widthPixels else 0.0,
            sourceId = src?.viewIdResourceName ?: "",
            fromIndex = e.fromIndex, toIndex = e.toIndex, itemCount = e.itemCount,
            scrollDeltaY = if (Build.VERSION.SDK_INT >= 28) e.scrollDeltaY else 0,
            screenHeight = dm.heightPixels,
            itemKey = key,
            nowMs = System.currentTimeMillis(),
        ))
    }

    fun showPillPublic() = main.post { rc?.reload() }
    fun hidePillPublic() = main.post { rc?.hidePublic() }

    /** The keyboard's package: its window is not an app switch (else scrolls in the app under it are dropped). */
    private fun imePkg(): String = try {
        android.provider.Settings.Secure.getString(contentResolver, android.provider.Settings.Secure.DEFAULT_INPUT_METHOD)?.substringBefore('/') ?: ""
    } catch (_: Exception) { "" }

    private fun onWindow(pkg: String) {
        if (pkg == currentPkg || pkg == packageName || pkg == "com.android.systemui" || pkg == imePkg()) return
        val now = System.currentTimeMillis()
        // leaving a long-video app: credit the watch only if no reel was counted meanwhile (same rule as below)
        if (currentVideoPkg.isNotEmpty() && !videoCountedForSession && currentVideoStart > 0L && (now - currentVideoStart) >= 35_000L &&
            now - (rc?.lastReelAt(currentVideoPkg) ?: 0L) >= 30_000L) {
            store.addLongVideo(currentVideoPkg)
        }
        currentVideoPkg = if (pkg in longVideoApps) pkg else ""
        currentVideoStart = if (currentVideoPkg.isNotEmpty()) now else 0L
        videoCountedForSession = false
        currentPkg = pkg

        // Per-app daily time limit (opt-in, set in Tools): a gentle note under the camera once a
        // day — never Home, never the whole app (the hard lock only ever bounces the reels feed).
        val timeLimitMin = RcPrefs(this).int("time_limit_$pkg", 0)
        if (timeLimitMin > 0 && (appMs[pkg] ?: 0L) >= timeLimitMin * 60_000L) {
            val day = ReelLockLogic.dayKey(now)
            if (timeNoticeDay[pkg] != day) {
                timeNoticeDay[pkg] = day
                val label = socialApps[pkg]?.optString("label")?.takeIf { it.isNotBlank() }
                    ?: try { packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString() } catch (_: Exception) { pkg }
                val p = mapOf("app" to label, "min" to "$timeLimitMin")
                val text = Strings.t(this, "limits.time_reached", p).let {
                    if (it == "limits.time_reached") "⏳ $label: your $timeLimitMin-minute limit for today is up." else it
                }
                CameraCapsule.status.show(this, text, CameraCapsule.AMBER, 5000)
            }
        }
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
        store.today()
            .put("screen_ms", todayMs)
            .put("current", currentPkg)
            .put("total_reels", store.totalReels())
            .put("total_long_videos", store.totalLongVideos())
    } catch (_: Throwable) {
        JSONObject().put("screen_ms", 0L).put("reels", JSONObject()).put("current", "").put("total_reels", 0).put("total_long_videos", 0)
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        try { (buttonCallback as? android.accessibilityservice.AccessibilityButtonController.AccessibilityButtonCallback)
            ?.let { accessibilityButtonController.unregisterAccessibilityButtonCallback(it) } } catch (_: Throwable) { }
        if (ReelLockController.active === lock) ReelLockController.active = null
        lock = null
        safe("stop") { rc?.stop() }
        rc = null
        instance = null
        safe("prefs") { RcPrefs(this).putLong(A11yHealth.PREF_DISCONNECTED_AT, System.currentTimeMillis()) }
        safe("chip_fallback") { ChipService.startIfWanted(applicationContext) }   // keep a chip via "Display over other apps" if allowed
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
