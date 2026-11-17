package live.snapy.app

import android.accessibilityservice.AccessibilityService
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import android.widget.Toast
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Real Count on the phone, independent of who hosts it:
 *  - the accessibility service (instant app changes + reel counting), or
 *  - ChipService ("Display over other apps", screen time only; app changes polled from usage events).
 * The accessibility host keeps its own pill and reel counter by default (externalCounter, showChip=false)
 * and feeds this class; RcPrefs chip_style = "island" switches to the chip drawn here.
 * Owns the chip, the cards, the counter (reels, creator mode, health check), the nudge engine
 * (NudgeEngine.kt, a port of nudges.dart), focus, pause, intention and the auto-hide signals.
 * Rules: bundled assets/rules/realcount.json < config android.realcount < snapy/rules/realcount.json (signed, verified in Dart).
 */
class RealCountController(
    private val ctx: Context,
    windowType: Int,
    /** reel numbers are available (the accessibility service is the host) */
    private val counting: Boolean,
    /** the host counts reels itself and reports them via shouldCount()/onReelCounted() */
    private val externalCounter: Boolean = false,
    /** draw the camera-centred chip (false: the host draws its own pill; cards/nudges still work) */
    private val showChip: Boolean = true,
) {
    private val main = Handler(Looper.getMainLooper())
    private val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val prefs = RcPrefs(ctx)
    private val store = RealCountStore(ctx)
    private val usage = UsageTracker(ctx)
    private val audio = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val keyguard = ctx.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
    private val speech by lazy { Speech(ctx) }
    private val imePkg: String by lazy {
        android.provider.Settings.Secure.getString(ctx.contentResolver, android.provider.Settings.Secure.DEFAULT_INPUT_METHOD)
            ?.substringBefore('/') ?: ""
    }

    @Volatile var rules = RealCountRules(JSONObject()); private set
    private var engine = NudgeEngine(rules)
    private var nudgeState = NudgeState.fromJson(try { JSONObject(prefs.str(RcPrefs.NUDGE_STATE)) } catch (_: Exception) { null })
    private var socialApps = mapOf<String, JSONObject>()
    private var minDwellMs = 700L
    private var refreshMs = 60_000L

    private val cards = OverlayCards(ctx, wm, windowType)
    private val chip: ChipOverlay = ChipOverlay(ctx, wm, windowType, object : ChipOverlay.Callbacks {
        override fun onOpenSheet() = openSheet("/sheet")
        override fun onLaunchApp(pkg: String) = launchSocialApp(pkg)
        override fun onTakeNote() {
            if (AudioNoteRecorder.isRecording) {
                val f = AudioNoteRecorder.stop(ctx)
                if (f != null) {
                    Toast.makeText(ctx, Strings.t(ctx, "chip.note_saved"), Toast.LENGTH_SHORT).show()
                }
            } else {
                val ok = AudioNoteRecorder.start(ctx)
                Toast.makeText(ctx, Strings.t(ctx, if (ok) "chip.note_recording" else "chip.note_failed"), Toast.LENGTH_SHORT).show()
            }
        }
        override fun onLongPress() = quickActions()
        override fun onSwipeDown() = breakdown()
        override fun onFullscreen(fullscreen: Boolean) { this@RealCountController.fullscreen = fullscreen; applyVisibility() }
    })

    // counter
    var currentPkg = ""; private set
    private var currentClass = ""
    private var inAppSince = 0L
    private val lastEventAt = HashMap<String, Long>()
    private val lastReelAt = HashMap<String, Long>()
    private val lastIndex = HashMap<String, Int>()
    private var reelTimeFrom = 0L
    private val session = ReelSession()
    private val opens = OpenTracker()
    private val lastIntentAsked = HashMap<String, Long>()
    @Volatile var todayMs = 0L; private set
    @Volatile var appMs = mapOf<String, Long>(); private set
    @Volatile private var limits = mapOf<String, Int>()
    @Volatile private var breakScreen = false
    @Volatile private var firstTask: String? = null
    private var firstTaskAt = 0L

    // auto-hide signals
    private var fullscreen = false
    private var locked = false
    private var inCall = false
    private var game = false
    private var listening = false
    private var started = false

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            locked = i.action == Intent.ACTION_SCREEN_OFF || (i.action == Intent.ACTION_SCREEN_ON && keyguard.isKeyguardLocked)
            if (i.action == Intent.ACTION_USER_PRESENT) locked = false
            applyVisibility()
        }
    }

    // ------------------------------------------------------------------ lifecycle
    fun start() {
        if (started) return
        started = true
        Thread { loadRules(); main.post { if (started) { showChipIfWanted(); tick(); signals() } } }.start()
        val f = IntentFilter().apply { addAction(Intent.ACTION_SCREEN_OFF); addAction(Intent.ACTION_SCREEN_ON); addAction(Intent.ACTION_USER_PRESENT) }
        if (Build.VERSION.SDK_INT >= 33) ctx.registerReceiver(screenReceiver, f, Context.RECEIVER_NOT_EXPORTED)
        else ctx.registerReceiver(screenReceiver, f)
        active = this
    }

    fun stop() {
        if (!started) return
        started = false
        flushReelTime()
        main.removeCallbacksAndMessages(null)
        try { ctx.unregisterReceiver(screenReceiver) } catch (_: Exception) { }
        chip.remove(); cards.remove()
        if (active === this) active = null
    }

    /** After Flutter changes settings (size, language, chip on/off…). */
    fun reload() = Thread {
        loadRules()
        Strings.reload()
        main.post { chip.remove(); showChipIfWanted() }
    }.start()

    private fun loadRules() {
        var merged = JSONObject()
        try {
            merged = JSONObject(ctx.assets.open("flutter_assets/assets/rules/realcount.json").bufferedReader().use { it.readText() })
        } catch (_: Exception) { }
        try {
            val core = CoreBridge.get(ctx)
            (try { JSONObject(core.configNow("android.realcount")) } catch (_: Exception) { null })?.let { merged = RealCountRules.deepMerge(merged, it) }
            val apps = JSONArray(core.configNow("android.social_apps"))
            val m = HashMap<String, JSONObject>()
            for (i in 0 until apps.length()) apps.getJSONObject(i).let { m[it.getString("package")] = it }
            socialApps = m
            minDwellMs = core.configNow("android.min_reel_dwell_ms").toLongOrNull() ?: minDwellMs
            refreshMs = (core.configNow("android.screen_time_refresh_s").toLongOrNull() ?: 60) * 1000
        } catch (_: Exception) { }
        try {
            val signed = File(ctx.filesDir, "snapy/rules/realcount.json")
            if (signed.exists()) merged = RealCountRules.deepMerge(merged, JSONObject(signed.readText()))
        } catch (_: Exception) { }
        // the user's bedtime wins over the default
        prefs.str("bedtime").takeIf { it.isNotEmpty() }?.let { bt ->
            merged = RealCountRules.deepMerge(merged, JSONObject().put("nudges", JSONObject().put("bedtime", bt)))
        }
        rules = RealCountRules(merged)
        engine = NudgeEngine(rules)
        counter.rules = ReelCounterRules.from(minDwellMs, merged)
    }

    private fun isSettingsOrSecurityApp(pkg: String): Boolean {
        if (pkg.isEmpty()) return true
        val lower = pkg.lowercase()
        return lower.contains("settings") ||
            lower.contains("permission") ||
            lower.contains("safecenter") ||
            lower.contains("security") ||
            lower.contains("packageinstaller") ||
            lower.contains("accessibility") ||
            lower.contains("permcenter") ||
            lower.contains("oppoguardelf") ||
            lower == "com.android.systemui"
    }

    private fun showChipIfWanted() {
        if (!showChip || !prefs.bool("chip_enabled")) { chip.remove(); return }
        if (currentPkg.isEmpty() || currentPkg == ctx.packageName || isSettingsOrSecurityApp(currentPkg)) {
            chip.remove()
            return
        }
        chip.show(rules)
        render()
        applyVisibility()
    }

    // ------------------------------------------------------------------ events from the host
    /** A short-video app of the catalogue (core rules android.social_apps, short_video set). */
    private fun isShortVideoApp(pkg: String): Boolean = socialApps[pkg]?.let { !it.isNull("short_video") } == true

    fun onWindow(pkg: String, cls: String) {
        if (pkg == "com.android.systemui" || pkg == imePkg) return     // keyboard isn't an app switch
        if (pkg == currentPkg) { if (cls.isNotEmpty()) currentClass = cls; return }
        flushReelTime()
        counter.reset(currentPkg)                                          // left the feed: a fresh run
        currentPkg = pkg
        currentClass = cls

        if (pkg == ctx.packageName || isSettingsOrSecurityApp(pkg)) {
            chip.remove()
            applyVisibility()
            return
        }

        val now = System.currentTimeMillis()
        val app = socialApps[pkg]
        inAppSince = if (app != null && !app.isNull("short_video")) now else 0L
        game = isGame(pkg)
        val isSocial = isShortVideoApp(pkg)

        if (showChip && !chip.isShown) {
            showChipIfWanted()
        }

        // 1. Live dynamic color palette extraction from launcher icon (zero hardcoding)
        val palette = AppPaletteExtractor.extract(ctx, pkg)
        chip.setDynamicPalette(palette)

        // 2. Set Reel counter mode for short video apps or screen time for utility apps
        if (isSocial) {
            val totalReels = store.totalReels()
            chip.setReelFeedMode(pkg, totalReels)
        } else {
            val currentAppMs = appMs[pkg] ?: 0L
            chip.setAppFeedMode(pkg, currentAppMs)
        }

        if (app != null) {
            opens.open(pkg, now)
            onSocialOpen(pkg, app, now)
        }
        applyVisibility()
        render()
    }

    fun hidePublic() = main.post { chip.remove() }

    fun setAppPalette(colors: IntArray?) = chip.setDynamicPalette(colors)
    fun setReelFeedMode(pkg: String, reels: Int) = chip.setReelFeedMode(pkg, reels)
    fun setAppFeedMode(pkg: String, ms: Long) = chip.setAppFeedMode(pkg, ms)

    /** The one reel counter (ReelCounter.kt, mirror of lib/realcount/reel_counter.dart). */
    private val counter = ReelCounter()
    /** The island chip is on screen (it shows its own subtitle for voice states). */
    val chipShown get() = chip.isShown
    /** Snapy's spoken reply in the chip's subtitle; false when the chip isn't shown. */
    fun subtitle(text: String): Boolean { if (!chip.isShown) return false; main.post { chip.showFloatingSubtitle(text) }; return true }
    /** Soundwave halo: the chip ring follows the mic level while listening / recording. */
    fun micLevel(level: Float) = chip.micLevel(level)

    /** Any scroll event from the app in front (health check: events are arriving). */
    fun onScrollEvent(pkg: String) { lastEventAt[pkg] = System.currentTimeMillis() }

    /** External counter: may this page change count? (creator mode, "pause counting"). */
    fun shouldCount(pkg: String, sourceId: String): Boolean =
        System.currentTimeMillis() >= prefs.long(RcPrefs.PAUSED_UNTIL) &&
            ChipLogic.countsAsFeed(rules, pkg, currentClass, sourceId, prefs.bool("creator_mode"))

    /** External counter: a reel was just counted (the host already wrote it to the store). */
    fun onReelCounted() {
        session.reel(System.currentTimeMillis(), rules.i("nudges.session_gap_min", 10) * 60000L)
        chip.setReelFeedMode(currentPkg, store.totalReels())
        render()
        decide(NudgeTrigger.REEL_COUNTED)
    }

    /**
     * THE reel counter (the accessibility service only forwards measured scroll events):
     * ReelCounter decides (catalogue app, full-screen pager, feed ids, creator screens,
     * page change incl. ViewPager2's -1 indices via the visible item's identity, dwell).
     * Mirror of lib/realcount/reel_counter.dart.
     */
    fun onScroll(e: ReelScroll) {
        if (!counting || externalCounter) { ReelDebug.add(e, "skip:not_counting"); return }
        if (e.pkg != currentPkg) { ReelDebug.add(e, "skip:not_current($currentPkg)"); return }
        lastEventAt[e.pkg] = e.nowMs                                         // health: events are arriving
        if (e.nowMs < prefs.long(RcPrefs.PAUSED_UNTIL)) { ReelDebug.add(e, "skip:paused"); return }   // "pause counting 1 h"
        if (prefs.bool("creator_mode") && !ChipLogic.countsAsFeed(rules, e.pkg, currentClass, e.sourceId, true)) { ReelDebug.add(e, "skip:creator"); return }
        val ev = e.copy(windowClass = currentClass, shortVideoApp = isShortVideoApp(e.pkg))
        val d = counter.onScroll(ev)
        ReelDebug.add(ev, d.name.lowercase())
        if (d != ReelDecision.COUNTED) return
        val now = e.nowMs
        lastReelAt[e.pkg] = now
        if (reelTimeFrom == 0L) reelTimeFrom = now
        store.addReel(e.pkg)
        session.reel(now, rules.i("nudges.session_gap_min", 10) * 60000L)
        chip.setReelFeedMode(e.pkg, store.totalReels())
        render()
        decide(NudgeTrigger.REEL_COUNTED)
        ReelLockController.active?.onReelCounted(e.pkg)                    // 80% deflector / hard lock
    }

    /** When the last reel was counted in [pkg] (long-video detection). */
    fun lastReelAt(pkg: String): Long = lastReelAt[pkg] ?: 0L

    fun onVoice(state: String, text: String) {
        listening = state == "listening" || state == "partial" || state == "thinking"
        applyVisibility()
        when (state) {
            "listening" -> chip.voice(if (text.isBlank()) Strings.t(ctx, "chip.listening") else text)
            "partial" -> chip.voice(text)
            "thinking" -> { chip.voice(Strings.t(ctx, "chip.thinking")); main.postDelayed({ listening = false; render(); applyVisibility() }, 6000) }
            else -> render()
        }
    }

    // ------------------------------------------------------------------ social app opened
    private fun onSocialOpen(pkg: String, app: JSONObject, now: Long) {
        val label = app.optString("label", pkg)
        val input = input(NudgeTrigger.APP_OPENED, now)
        if (!inCall && !navigating() && engine.pauseBeforeOpen(input, breakScreen)) {
            openSheet("/break?app=${Uri.encode(label)}&s=${rules.i("nudges.break_s", 10)}")
            return
        }
        if (decide(NudgeTrigger.APP_OPENED)) return
        val focusOn = now < prefs.long(RcPrefs.FOCUS_UNTIL)
        val planRunning = now < prefs.long(RcPrefs.INTENT_ENDS)
        if (!inCall && !navigating() && prefs.bool("nudges") &&
            ChipLogic.shouldAskIntention(rules, now, lastIntentAsked[pkg] ?: 0L, prefs.bool("intention_prompt"), focusOn, planRunning)) {
            lastIntentAsked[pkg] = now
            askIntention(label)
        }
    }

    private fun askIntention(label: String) {
        val opts = ChipLogic.intentionOptions(rules)
        if (opts.isEmpty()) return
        val actions = opts.map { it.id to Strings.t(ctx, "intent.${it.id}", mapOf("minutes" to "${it.minutes}")) } +
            ("skip" to Strings.t(ctx, "intent.skip"))
        cards.show(Strings.t(ctx, "intent.title"), label, actions, chipBottom(), rules.i("chip.card_ms", 6000) * 2L, big()) { id ->
            val o = opts.firstOrNull { it.id == id } ?: return@show
            prefs.putString(RcPrefs.INTENT_ID, o.id)
            prefs.putLong(RcPrefs.INTENT_MIN, o.minutes.toLong())
            prefs.putLong(RcPrefs.INTENT_ENDS, System.currentTimeMillis() + o.minutes * 60000L)
            cards.show(null, Strings.t(ctx, "intent.set", mapOf("minutes" to "${o.minutes}")), emptyList(), chipBottom(), 2500, big()) { }
        }
    }

    // ------------------------------------------------------------------ nudges
    private fun navigating() = rules.list("nudges.navigation_apps").contains(currentPkg)

    private fun input(trigger: NudgeTrigger, now: Long): NudgeInput {
        val app = socialApps[currentPkg]
        val gap = rules.i("nudges.session_gap_min", 10) * 60000L
        val active = session.active(now, gap)
        val intentEnds = prefs.long(RcPrefs.INTENT_ENDS)
        return NudgeInput(
            nowMs = now,
            trigger = trigger,
            pkg = currentPkg,
            label = app?.optString("label", currentPkg) ?: currentPkg,
            shortVideo = app != null && !app.isNull("short_video"),
            sessionReels = if (active) session.count else 0,
            sessionStartMs = session.startMs,
            sessionMinutes = if (active) session.minutes() else 0,
            opensLastHour = opens.lastHour(currentPkg, now),
            limitFraction = if (app != null) fraction() else 0.0,
            inCall = inCall,
            navigating = navigating(),
            focusUntilMs = prefs.long(RcPrefs.FOCUS_UNTIL),
            intentionEndsMs = if (app != null) intentEnds else 0L,
            intentionId = prefs.str(RcPrefs.INTENT_ID).ifEmpty { null },
            intentionMinutes = prefs.long(RcPrefs.INTENT_MIN).toInt(),
            voiceOn = prefs.bool("speak_nudges"),
            firstTaskTomorrow = firstTask,
        )
    }

    /** true when a card was shown. */
    private fun decide(trigger: NudgeTrigger): Boolean {
        if (!prefs.bool("nudges") || (showChip && !chip.isShown)) return false
        val now = System.currentTimeMillis()
        val n = engine.decide(input(trigger, now), nudgeState) ?: return false
        engine.shown(n, nudgeState, now)
        if (n.kind == NudgeKind.INTENTION_DONE) { prefs.putLong(RcPrefs.INTENT_ENDS, 0); prefs.putString(RcPrefs.INTENT_ID, "") }
        saveNudgeState()
        val text = Strings.t(ctx, n.key, n.params)
        if (n.pulse) chip.pulse()
        if (n.speak) speech.speak(text, Strings.lang(ctx))
        val actions = n.actions.map { it to Strings.t(ctx, "action.$it") }
        cards.show(null, text, actions, chipBottom(), rules.i("chip.card_ms", 6000).toLong(), big()) { act(n, it) }
        return true
    }

    private fun act(n: Nudge, action: String) {
        when (action) {
            "dismiss" -> { engine.dismissed(nudgeState, System.currentTimeMillis()); saveNudgeState() }
            "reset" -> openSheet("/reset?app=${Uri.encode(socialApps[currentPkg]?.optString("label") ?: "")}")
            "focus" -> startFocus(rules.i("nudges.focus_min", 25))
            "back_to_focus", "wrap_up", "wind_down" -> goHome()
            else -> {}                                                       // keep_going, open_anyway
        }
        render()
    }

    private fun saveNudgeState() = prefs.putString(RcPrefs.NUDGE_STATE, nudgeState.toJson().toString())

    fun startFocus(minutes: Int) {
        val until = System.currentTimeMillis() + minutes * 60000L
        prefs.putLong(RcPrefs.FOCUS_UNTIL, until)
        cards.show(null, Strings.t(ctx, "focus.started", mapOf("until" to engine.clock(until))), emptyList(), chipBottom(), 2500, big()) { }
    }

    // ------------------------------------------------------------------ chip gestures
    private fun quickActions() {
        val focusMin = rules.i("nudges.focus_min", 25)
        val pauseMin = rules.i("nudges.pause_counting_min", 60)
        val paused = System.currentTimeMillis() < prefs.long(RcPrefs.PAUSED_UNTIL)
        val sizes = listOf("small", "normal", "large")
        val next = sizes[(sizes.indexOf(prefs.str("chip_size")).coerceAtLeast(0) + 1) % sizes.size]
        val actions = mutableListOf(
            "focus" to Strings.t(ctx, "quick.focus", mapOf("min" to "$focusMin")),
            (if (paused) "resume" else "pause") to (if (paused) Strings.t(ctx, "quick.resume") else Strings.t(ctx, "quick.pause", mapOf("min" to "$pauseMin"))),
            "hide_today" to Strings.t(ctx, "quick.hide_today"),
        )
        if (!prefs.bool("simple_mode")) {
            actions += "size" to Strings.t(ctx, "quick.size", mapOf("size" to Strings.t(ctx, "size.$next")))
            if (prefs.int("chip_x") >= 0) actions += "reset_position" to Strings.t(ctx, "quick.reset_position")
        }
        cards.show(Strings.t(ctx, "quick.title"), "", actions, chipBottom(), 8000, big()) { id ->
            when (id) {
                "focus" -> startFocus(focusMin)
                "pause" -> prefs.putLong(RcPrefs.PAUSED_UNTIL, System.currentTimeMillis() + pauseMin * 60000L)
                "resume" -> prefs.putLong(RcPrefs.PAUSED_UNTIL, 0)
                "hide_today" -> { prefs.putString("hidden_day", engine.dayKey(System.currentTimeMillis())); applyVisibility() }
                "size" -> { prefs.putString("chip_size", next); chip.rebuild(rules); render(); applyVisibility() }
                "reset_position" -> { prefs.update(JSONObject().put("chip_x", -1).put("chip_y", -1)); chip.place(rules) }
            }
        }
    }

    private fun breakdown() {
        val reels = store.today().optJSONObject("apps") ?: JSONObject()
        val pm = ctx.packageManager
        val rows = appMs.entries.sortedByDescending { it.value }.take(6).map { (pkg, ms) ->
            val label = socialApps[pkg]?.optString("label") ?: try { pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString() } catch (_: Exception) { pkg }
            val n = reels.optJSONObject(pkg)?.optInt("reels") ?: 0
            "$label   ${ChipLogic.formatDuration(ms)}" + if (n > 0) "  ·  " + Strings.t(ctx, "breakdown.reels", mapOf("n" to "$n")) else ""
        }
        val body = if (rows.isEmpty()) Strings.t(ctx, "breakdown.empty") else rows.joinToString("\n")
        cards.show(Strings.t(ctx, "breakdown.title", mapOf("time" to ChipLogic.formatDuration(todayMs))), body, emptyList(), chipBottom(), 8000, big()) { }
    }

    // ------------------------------------------------------------------ chip text, tone, visibility
    private fun fraction(): Double {
        val lim = limits[currentPkg] ?: 0
        return ChipLogic.limitFraction(appMs[currentPkg] ?: 0L, lim, store.totalReels(), prefs.int("reel_limit"))
    }

    fun pausedApps(): List<String> {
        val now = System.currentTimeMillis()
        val stale = rules.i("health.stale_after_s", 180) * 1000L
        return if (counting && inAppSince > 0 && ChipLogic.counterPaused(now, inAppSince, lastEventAt[currentPkg] ?: 0L, stale)) listOf(currentPkg) else emptyList()
    }

    fun render() = main.post {
        if (listening || !chip.isShown) return@post
        val now = System.currentTimeMillis()
        val time = ChipLogic.formatDuration(todayMs)
        val paused = pausedApps().isNotEmpty()
        val reels = if (counting) "${store.totalReels()}" else "—"
        val f = fraction()
        val tone = ChipLogic.tone(f, rules.d("chip.amber_at", 1.0), engine.isBedtime(now), paused)
        val full = if (paused) Strings.t(ctx, "chip.paused_time", mapOf("time" to time)) else "$time · 🎞 $reels"
        // split around the camera gap: time on the left, the rest on the right
        val left = if (full.startsWith(time)) time else full
        val right = if (full.startsWith(time)) full.removePrefix(time).trim() else ""
        chip.render(left, right, tone, ChipLogic.ring(f), "$time · $reels reels")
    }

    private fun applyVisibility() = main.post {
        val today = engine.dayKey(System.currentTimeMillis())
        chip.setHidden(ChipLogic.hidden(fullscreen, game, locked, inCall, !prefs.bool("chip_enabled"),
            prefs.str("hidden_day") == today, System.currentTimeMillis() < prefs.long(RcPrefs.HIDDEN_UNTIL), listening))
    }

    private fun isGame(pkg: String): Boolean = try {
        val ai = ctx.packageManager.getApplicationInfo(pkg, 0)
        @Suppress("DEPRECATION")
        (Build.VERSION.SDK_INT >= 26 && ai.category == ApplicationInfo.CATEGORY_GAME) || (ai.flags and ApplicationInfo.FLAG_IS_GAME) != 0
    } catch (_: Exception) { false }

    // ------------------------------------------------------------------ loops
    private fun tick() {
        if (!started) return
        Thread {
            val t = usage.today()
            todayMs = t.totalMs
            appMs = t.perApp
            try {
                val core = CoreBridge.get(ctx)
                if (core.isReady()) {
                    val per = JSONObject(); t.perApp.forEach { (k, v) -> per.put(k, v) }
                    core.call("update_usage", JSONObject().put("screen_ms", t.totalMs).put("per_app_ms", per)
                        .put("opens", JSONObject(t.opens as Map<*, *>)).toString()) { }
                    core.call("limits_json") { j ->
                        try {
                            val o = JSONObject(j)
                            val l = o.optJSONObject("limits") ?: JSONObject()
                            limits = l.keys().asSequence().associateWith { l.optInt(it) }
                            breakScreen = o.optBoolean("break")
                        } catch (_: Exception) { }
                    }
                    val now = System.currentTimeMillis()
                    if (engine.isBedtime(now) && now - firstTaskAt > 30 * 60000L) {
                        firstTaskAt = now
                        core.call("snapshot") { s -> firstTask = firstTaskOf(s) }
                    }
                }
            } catch (_: Exception) { }
            main.post { render(); decide(NudgeTrigger.TICK) }
        }.start()
        main.postDelayed({ tick() }, refreshMs)
    }

    /** Cheap signals every few seconds: calls (audio mode: no phone permission needed) and the lock screen. */
    private fun signals() {
        if (!started) return
        val call = audio.mode == AudioManager.MODE_IN_CALL || audio.mode == AudioManager.MODE_IN_COMMUNICATION
        val lock = keyguard.isKeyguardLocked
        if (call != inCall || lock != locked) { inCall = call; locked = lock; applyVisibility() }
        main.postDelayed({ signals() }, 3000)
    }

    /** Fallback host: which app is in front, from usage events (no accessibility). */
    fun pollForeground() {
        Thread {
            val pkg = usage.foreground() ?: return@Thread
            main.post { onWindow(pkg, "") }
        }.start()
    }

    private fun flushReelTime() {
        if (externalCounter || reelTimeFrom == 0L || currentPkg.isEmpty()) return
        val end = (lastReelAt[currentPkg] ?: reelTimeFrom) + 60_000
        store.addReelTime(currentPkg, (minOf(end, System.currentTimeMillis()) - reelTimeFrom).coerceAtLeast(0))
        reelTimeFrom = 0L
        store.save()
    }

    // ------------------------------------------------------------------ helpers
    private fun big() = prefs.bool("simple_mode")
    private fun chipBottom() = if (chip.isShown) chip.y + chip.height else (40 * ctx.resources.displayMetrics.density).toInt()

    fun openSheet(route: String) {
        cards.remove()
        ctx.startActivity(Intent(ctx, SheetActivity::class.java).putExtra("route", route).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    fun launchSocialApp(targetPkg: String) {
        // the asked app, else the first installed short-video app of the catalogue (no hardcoded packages)
        val target = targetPkg.takeIf { it.isNotEmpty() && isPackageInstalled(it) }
            ?: socialApps.values.filter { !it.isNull("short_video") }.map { it.optString("package") }.firstOrNull { isPackageInstalled(it) }
            ?: ctx.packageName
        try {
            val intent = ctx.packageManager.getLaunchIntentForPackage(target)
            if (intent != null) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
                ctx.startActivity(intent)
            }
        } catch (_: Exception) {}
    }

    private fun isPackageInstalled(pkg: String): Boolean = try {
        ctx.packageManager.getPackageInfo(pkg, 0)
        true
    } catch (_: Exception) { false }

    private fun goHome() {
        val svc = ctx as? AccessibilityService
        if (svc == null || !svc.performGlobalAction(AccessibilityService.GLOBAL_ACTION_HOME)) {
            ctx.startActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    fun todayJson(): JSONObject = store.today()
        .put("screen_ms", todayMs)
        .put("current", currentPkg)
        .put("total_reels", store.totalReels())
        .put("total_long_videos", store.totalLongVideos())

    fun stateJson(): JSONObject {
        val now = System.currentTimeMillis()
        return JSONObject()
            .put("mode", if (counting) "accessibility" else "overlay")
            .put("focus_until", prefs.long(RcPrefs.FOCUS_UNTIL).takeIf { it > now } ?: 0L)
            .put("paused_until", prefs.long(RcPrefs.PAUSED_UNTIL).takeIf { it > now } ?: 0L)
            .put("hidden_day", prefs.str("hidden_day"))
            .put("intention", JSONObject().put("id", prefs.str(RcPrefs.INTENT_ID)).put("ends", prefs.long(RcPrefs.INTENT_ENDS)))
            .put("paused_apps", JSONArray(pausedApps()))
            .put("session_reels", if (session.active(now, rules.i("nudges.session_gap_min", 10) * 60000L)) session.count else 0)
    }

    companion object {
        /** The running controller (accessibility service or ChipService), if any. */
        @Volatile var active: RealCountController? = null

        /** Tomorrow's first task from the brain's snapshot (else the first pending task). */
        fun firstTaskOf(snapshot: String): String? = try {
            val tasks = JSONObject(snapshot).optJSONArray("tasks") ?: JSONArray()
            val tomorrow = java.time.LocalDate.now().plusDays(1).toString()
            val list = (0 until tasks.length()).map { tasks.getJSONObject(it) }
            (list.filter { it.optString("remind_at").startsWith(tomorrow) }.minByOrNull { it.optString("remind_at") } ?: list.firstOrNull())
                ?.optString("title")?.takeIf { it.isNotBlank() }
        } catch (_: Exception) { null }
    }
}
