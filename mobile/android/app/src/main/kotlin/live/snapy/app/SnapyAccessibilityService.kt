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

    private var pillLayout: LinearLayout? = null
    private var orbView: LivingOrbView? = null
    private var counterBadge: LinearLayout? = null
    private var counterText: TextView? = null
    private var liquidOverlay: View? = null
    private var isSocialActive = false
    private var card: View? = null

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
    private var lastNudge = HashMap<String, Long>()
    private var todayMs = 0L
    private var appMs = mapOf<String, Long>()
    private var hiddenUntil = 0L
    /** Phase 5: nudges, focus, intention, creator mode, health (RealCountController). With
     *  RcPrefs chip_style = "island" it also draws the camera-centred chip instead of this pill. */
    private var rc: RealCountController? = null
    private val island get() = RcPrefs(this).str("chip_style") == "island"

    override fun onServiceConnected() {
        instance = this
        wm = getSystemService(WINDOW_SERVICE) as WindowManager
        store = RealCountStore(this)
        usage = UsageTracker(this)
        loadConfig()
        ChipService.stop(this)                           // the counter's own chip replaces the fallback one
        rc = RealCountController(this, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY, counting = true,
            externalCounter = true, showChip = island).also { it.start() }
        if (!island) showPill()
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
        when (e.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> { onWindow(pkg); rc?.onWindow(pkg, e.className?.toString() ?: "") }
            AccessibilityEvent.TYPE_VIEW_SCROLLED -> if (pkg == currentPkg) { rc?.onScrollEvent(pkg); onScroll(pkg, e) }
        }
    }

    fun showPillPublic() = main.post { if (island) rc?.reload() else showPill() }

    private fun onWindow(pkg: String) {
        if (pkg == currentPkg || pkg == packageName || pkg == "com.android.systemui") return
        flushReelTime()
        val prev = currentPkg
        currentPkg = pkg

        val isSocial = socialApps.containsKey(pkg) && !socialApps[pkg]!!.isNull("short_video")
        setSocialAppActive(isSocial)

        if (socialApps.containsKey(pkg) && pkg != prev && rc == null) nudge(pkg)    // the nudge engine replaces this card
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
        if (rc?.shouldCount(pkg, src?.viewIdResourceName ?: "") == false) return   // creator mode / paused counting
        lastReelAt[pkg] = now
        if (reelTimeFrom == 0L) reelTimeFrom = now
        store.addReel(pkg)
        rc?.onReelCounted()
        animateReelNumberDrop()
        updatePill()

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

    // ------------------------------------------------------------------ floating AI orb
    private fun dp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics).toInt()

    private fun showPill() {
        if (pillLayout != null) return
        val size = dp(26f)

        val container = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            clipChildren = false
            clipToPadding = false
        }

        val orb = LivingOrbView(this).apply {
            layoutParams = LinearLayout.LayoutParams(size, size)
        }
        orbView = orb
        container.addView(orb)

        val badge = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            visibility = if (isSocialActive) View.VISIBLE else View.GONE
            setPadding(dp(7f), dp(2f), dp(8f), dp(2f))
            background = GradientDrawable().apply {
                cornerRadius = dp(11f).toFloat()
                setColor(0xEE161824.toInt())
                setStroke(dp(1f), 0x2EFFFFFF)
            }
            val tv = TextView(this@SnapyAccessibilityService).apply {
                text = "${store.totalReels()}"
                setTextColor(0xFFFFFFFF.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
                typeface = Typeface.create("sans-serif-bold", Typeface.BOLD)
                fontFeatureSettings = "tnum"
            }
            counterText = tv
            addView(tv)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                dp(22f)
            ).apply {
                leftMargin = dp(4f)
            }
        }
        counterBadge = badge
        container.addView(badge)

        container.setOnClickListener {
            orb.nextPalette()
            toggleLiquidCard()
        }
        container.setOnLongClickListener {
            hiddenUntil = System.currentTimeMillis() + 3600_000
            updatePill()
            Toast.makeText(this@SnapyAccessibilityService, "Snapy dot hidden for 1 hour", Toast.LENGTH_SHORT).show()
            true
        }

        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            size,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        )
        if (Build.VERSION.SDK_INT >= 30) lp.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        placeBesideCamera(lp, size)

        wm.addView(container, lp)
        pillLayout = container
        updatePill()
    }

    private fun setSocialAppActive(active: Boolean) = main.post {
        if (isSocialActive == active) return@post
        isSocialActive = active
        val badge = counterBadge ?: return@post
        val tv = counterText ?: return@post

        if (active) {
            val count = store.totalReels()
            tv.text = "$count"
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
                .withEndAction {
                    badge.visibility = View.GONE
                }
                .start()
        }
    }

    private fun animateReelNumberDrop() = main.post {
        val badge = counterBadge ?: return@post
        val tv = counterText ?: return@post
        if (badge.visibility != View.VISIBLE) {
            badge.visibility = View.VISIBLE
        }
        val count = store.totalReels()
        tv.animate()
            .translationY(-dp(8f).toFloat())
            .alpha(0f)
            .setDuration(110)
            .withEndAction {
                tv.text = "$count"
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

    /** Sit permanently in the status-bar row right beside the camera punch-hole (non-draggable). */
    private fun placeBesideCamera(lp: WindowManager.LayoutParams, size: Int) {
        lp.gravity = Gravity.TOP or Gravity.START
        val width = resources.displayMetrics.widthPixels
        var y = dp(4f)
        var x = (width / 2) + dp(26f)

        if (Build.VERSION.SDK_INT >= 30) {
            val insets = wm.currentWindowMetrics.windowInsets
            val bar = insets.getInsets(WindowInsets.Type.statusBars()).top
            if (bar > 0) y = ((bar - size) / 2).coerceAtLeast(0)

            val cutout = insets.displayCutout
            if (cutout != null && cutout.boundingRects.isNotEmpty()) {
                val r = cutout.boundingRects[0]
                x = (r.right + dp(6f)).coerceIn(dp(12f), width - size - dp(12f))
                if (r.height() > size) {
                    y = (r.top + (r.height() - size) / 2).coerceAtLeast(0)
                }
            }
        }
        lp.x = x
        lp.y = y
    }

    private fun updatePill() = main.post {
        val p = pillLayout ?: return@post
        p.visibility = if (System.currentTimeMillis() < hiddenUntil) View.GONE else View.VISIBLE
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

    // ------------------------------------------------------------------ liquid flow card
    private fun toggleLiquidCard() {
        if (liquidOverlay != null) dismissLiquidCard() else showLiquidCard()
    }

    private fun dismissLiquidCard() {
        val overlay = liquidOverlay ?: return
        val card = overlay.findViewById<View>(android.R.id.content) ?: overlay
        card.animate()
            .scaleX(0.25f)
            .scaleY(0.05f)
            .translationY(-dp(20f).toFloat())
            .alpha(0f)
            .setDuration(180)
            .setInterpolator(AccelerateInterpolator(1.4f))
            .withEndAction {
                try { wm.removeView(overlay) } catch (_: Exception) {}
                if (liquidOverlay == overlay) liquidOverlay = null
            }
            .start()
    }

    private fun showLiquidCard() {
        dismissLiquidCard()
        val screenW = resources.displayMetrics.widthPixels
        val cardW = minOf(screenW - dp(24f), dp(360f))

        // Full-screen touch overlay: tapping outside automatically dismisses!
        val overlay = FrameLayout(this).apply {
            setBackgroundColor(0x00000000)
            setOnClickListener { dismissLiquidCard() }
        }

        // Executive obsidian liquid card
        val cardRoot = LinearLayout(this).apply {
            id = android.R.id.content
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18f), dp(16f), dp(18f), dp(14f))
            background = GradientDrawable().apply {
                cornerRadius = dp(20f).toFloat()
                setColor(0xF215161E.toInt()) // Deep executive obsidian (95% opaque)
                setStroke(dp(1f), 0x22FFFFFF) // Clean subtle hairline
            }
            elevation = dp(14f).toFloat()
            setOnClickListener { /* consume click inside card */ }
        }

        // 1. Minimalist Header (NO CROSS ICON)
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(View(this@SnapyAccessibilityService).apply {
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(0xFF28C8FF.toInt())
                }
                layoutParams = LinearLayout.LayoutParams(dp(7f), dp(7f))
            })
            addView(TextView(this@SnapyAccessibilityService).apply {
                text = "  Screen Activity"
                setTextColor(0xFFF5F5F7.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f)
                typeface = Typeface.create("sans-serif-bold", Typeface.BOLD)
            })
            val spacer = View(this@SnapyAccessibilityService).apply {
                layoutParams = LinearLayout.LayoutParams(0, 0, 1f)
            }
            addView(spacer)
            addView(TextView(this@SnapyAccessibilityService).apply {
                text = "TODAY"
                setTextColor(0xFF8E8E93.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
                typeface = Typeface.create("sans-serif-bold", Typeface.BOLD)
                setPadding(dp(7f), dp(2f), dp(7f), dp(2f))
                background = GradientDrawable().apply {
                    cornerRadius = dp(6f).toFloat()
                    setColor(0x18FFFFFF)
                }
            })
        }
        cardRoot.addView(header)

        // 2. Metrics Panel (Clean two-column corporate layout)
        val metricsPanel = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(14f), dp(12f), dp(14f), dp(12f))
            background = GradientDrawable().apply {
                cornerRadius = dp(14f).toFloat()
                setColor(0x1C222432)
                setStroke(dp(1f), 0x1AFFFFFF)
            }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                topMargin = dp(12f)
                bottomMargin = dp(12f)
            }

            val timeCol = LinearLayout(this@SnapyAccessibilityService).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                addView(TextView(this@SnapyAccessibilityService).apply {
                    text = "SCREEN TIME"
                    setTextColor(0xFF8E8E93.toInt())
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 9.5f)
                    typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                })
                addView(TextView(this@SnapyAccessibilityService).apply {
                    text = "⏱ " + UsageTracker.format(todayMs)
                    setTextColor(0xFFF5F5F7.toInt())
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
                    typeface = Typeface.create("sans-serif-bold", Typeface.BOLD)
                    fontFeatureSettings = "tnum"
                    setPadding(0, dp(3f), 0, 0)
                })
            }

            val reelCol = LinearLayout(this@SnapyAccessibilityService).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                addView(TextView(this@SnapyAccessibilityService).apply {
                    text = "REELS SCROLLED"
                    setTextColor(0xFF8E8E93.toInt())
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 9.5f)
                    typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                })
                addView(TextView(this@SnapyAccessibilityService).apply {
                    text = "▶ " + store.totalReels()
                    setTextColor(0xFF5E81FF.toInt())
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
                    typeface = Typeface.create("sans-serif-bold", Typeface.BOLD)
                    fontFeatureSettings = "tnum"
                    setPadding(0, dp(3f), 0, 0)
                })
            }

            addView(timeCol)
            addView(reelCol)
        }
        cardRoot.addView(metricsPanel)

        // 3. Horizontal Scroll of Used Apps
        val labelRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(2f), 0, dp(6f))
            addView(TextView(this@SnapyAccessibilityService).apply {
                text = "APPS USED TODAY"
                setTextColor(0xFF8E8E93.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
                typeface = Typeface.create("sans-serif-bold", Typeface.BOLD)
            })
        }
        cardRoot.addView(labelRow)

        val pm = packageManager
        val candidatePkgs = LinkedHashSet<String>()
        candidatePkgs.addAll(socialApps.keys)
        try {
            val todayApps = store.today().optJSONObject("apps")
            if (todayApps != null) {
                val iter = todayApps.keys()
                while (iter.hasNext()) candidatePkgs.add(iter.next())
            }
        } catch (_: Exception) {}
        for (pkg in appMs.keys) {
            if ((appMs[pkg] ?: 0L) >= 60_000L && (pkg.contains("instagram") || pkg.contains("youtube") || pkg.contains("facebook") || pkg.contains("snapchat") || pkg.contains("tiktok") || pkg.contains("twitter") || pkg.contains("reddit") || pkg.contains("whatsapp") || pkg.contains("reels") || pkg.contains("short"))) {
                candidatePkgs.add(pkg)
            }
        }

        data class UsedAppItem(
            val pkg: String,
            val label: String,
            val icon: Drawable?,
            val reels: Int,
            val timeMs: Long
        )
        val usedApps = mutableListOf<UsedAppItem>()

        for (pkg in candidatePkgs) {
            val reels = store.reels(pkg)
            val ms = appMs[pkg] ?: 0L
            if (reels <= 0 && ms < 60_000L) continue

            try {
                val appInfo = pm.getApplicationInfo(pkg, 0)
                val appLabel = pm.getApplicationLabel(appInfo).toString()
                val appIcon = pm.getApplicationIcon(appInfo)
                usedApps.add(UsedAppItem(pkg, appLabel, appIcon, reels, ms))
            } catch (_: Exception) {
                continue
            }
        }
        usedApps.sortByDescending { it.reels * 1_000_000L + it.timeMs }

        val hScroll = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_IF_CONTENT_SCROLLS
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                bottomMargin = dp(10f)
            }
        }

        val hContainer = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(2f), 0, dp(4f))
        }

        if (usedApps.isEmpty()) {
            val emptyCard = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(12f), dp(10f), dp(12f), dp(10f))
                background = GradientDrawable().apply {
                    cornerRadius = dp(12f).toFloat()
                    setColor(0x14FFFFFF)
                }
                addView(TextView(this@SnapyAccessibilityService).apply {
                    text = "✨ No feeds scrolled yet today — 100% focused"
                    setTextColor(0xFFA1A1A6.toInt())
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
                })
            }
            hContainer.addView(emptyCard)
        } else {
            for (item in usedApps) {
                val appCard = LinearLayout(this).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.CENTER_HORIZONTAL
                    setPadding(dp(10f), dp(9f), dp(10f), dp(9f))
                    background = GradientDrawable().apply {
                        cornerRadius = dp(14f).toFloat()
                        setColor(0x24222432)
                        setStroke(dp(1f), 0x1AFFFFFF)
                    }
                    layoutParams = LinearLayout.LayoutParams(dp(106f), LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                        rightMargin = dp(8f)
                    }

                    // Real App Icon
                    val iv = ImageView(this@SnapyAccessibilityService).apply {
                        layoutParams = LinearLayout.LayoutParams(dp(36f), dp(36f)).apply {
                            gravity = Gravity.CENTER_HORIZONTAL
                            bottomMargin = dp(5f)
                        }
                        if (item.icon != null) {
                            setImageDrawable(item.icon)
                        } else {
                            setImageResource(android.R.drawable.sym_def_app_icon)
                        }
                        scaleType = ImageView.ScaleType.FIT_CENTER
                    }
                    addView(iv)

                    // App Label
                    val nameTv = TextView(this@SnapyAccessibilityService).apply {
                        text = item.label
                        setTextColor(0xFFF5F5F7.toInt())
                        setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
                        typeface = Typeface.create("sans-serif-bold", Typeface.BOLD)
                        maxLines = 1
                        ellipsize = TextUtils.TruncateAt.END
                        gravity = Gravity.CENTER_HORIZONTAL
                    }
                    addView(nameTv)

                    // Reels Scrolled
                    val reelsTv = TextView(this@SnapyAccessibilityService).apply {
                        text = if (item.reels > 0) "▶ ${item.reels} reels" else "0 reels"
                        setTextColor(if (item.reels > 0) 0xFF5E81FF.toInt() else 0xFF8E8E93.toInt())
                        setTextSize(TypedValue.COMPLEX_UNIT_SP, 10.5f)
                        typeface = Typeface.create("sans-serif-bold", Typeface.BOLD)
                        fontFeatureSettings = "tnum"
                        gravity = Gravity.CENTER_HORIZONTAL
                        setPadding(0, dp(1f), 0, 0)
                    }
                    addView(reelsTv)

                    // Active Time
                    if (item.timeMs >= 60_000L) {
                        val timeTv = TextView(this@SnapyAccessibilityService).apply {
                            text = "⏱ " + UsageTracker.format(item.timeMs)
                            setTextColor(0xFF8E8E93.toInt())
                            setTextSize(TypedValue.COMPLEX_UNIT_SP, 9.5f)
                            fontFeatureSettings = "tnum"
                            gravity = Gravity.CENTER_HORIZONTAL
                        }
                        addView(timeTv)
                    }

                    setOnClickListener {
                        dismissLiquidCard()
                        openSheet()
                    }
                }
                hContainer.addView(appCard)
            }
        }
        hScroll.addView(hContainer)
        cardRoot.addView(hScroll)

        // 4. Minimalist AI Hint (NOT a chunky button)
        val hintRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(8f), dp(8f), dp(8f), dp(4f))
            addView(TextView(this@SnapyAccessibilityService).apply {
                text = "✨ Ask Snapy about your screen habits ➔"
                setTextColor(0xFFA1A1A6.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            })
            setOnClickListener {
                dismissLiquidCard()
                openSheet()
            }
        }
        cardRoot.addView(hintRow)

        var yPos = dp(44f)
        if (Build.VERSION.SDK_INT >= 30) {
            val insets = wm.currentWindowMetrics.windowInsets
            val bar = insets.getInsets(WindowInsets.Type.statusBars()).top
            if (bar > 0) yPos = bar + dp(8f)
        }

        overlay.addView(cardRoot, FrameLayout.LayoutParams(
            cardW, FrameLayout.LayoutParams.WRAP_CONTENT
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            topMargin = yPos
        })

        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        )

        wm.addView(overlay, lp)
        liquidOverlay = overlay

        // Fluid "drop from that icon and expand" animation
        cardRoot.pivotX = cardW / 2f
        cardRoot.pivotY = 0f
        cardRoot.scaleX = 0.25f
        cardRoot.scaleY = 0.05f
        cardRoot.translationY = -dp(24f).toFloat()
        cardRoot.alpha = 0f
        cardRoot.animate()
            .scaleX(1.0f)
            .scaleY(1.0f)
            .translationY(0f)
            .alpha(1.0f)
            .setDuration(280)
            .setInterpolator(DecelerateInterpolator(2.0f))
            .start()
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
        rc?.onVoice(state, text)
        val p = pillLayout ?: return@post
        p.visibility = View.VISIBLE
        if (state == "listening" || state == "thinking") {
            orbView?.nextPalette()
        }
    }

    /** Today's numbers for the app/dashboard and the AI. */
    fun todayJson(): JSONObject = store.today().put("screen_ms", todayMs).put("current", currentPkg)

    override fun onInterrupt() {}

    override fun onDestroy() {
        flushReelTime()
        orbView?.stop()
        pillLayout?.let {
            try { wm.removeView(it) } catch (_: Exception) { }
        }
        dismissLiquidCard()
        removeCard()
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
