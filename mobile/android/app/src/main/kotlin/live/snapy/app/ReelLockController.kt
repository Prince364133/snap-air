package live.snapy.app

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import org.json.JSONObject

/**
 * The hard lock and the 80% dopamine deflector (docs/ANDROID_NEXT_PLAN.md §3), inside the
 * accessibility service. Decisions: [ReelLockLogic] / [BounceTracker] (mirrors of
 * lib/realcount/reel_lock.dart). Only the SHORT-VIDEO FEED is bounced (Back); DMs, profile,
 * the photo feed and the rest of the app keep working; never Home unless the feed is still on
 * screen after the Backs (then the app's own start screen first).
 *
 * Feed detection (≤150 ms budget from the accessibility event to Back; notificationTimeout is
 * 100 ms, so a fresh event is handled at once, no polling):
 *   1. the app's pager view ids (core rules android.realcount.creator.apps.<pkg>.feed_view_ids,
 *      plus android.realcount.feed.<pkg>.view_ids when present — signed-rules updatable);
 *   2. otherwise the full-screen vertical pager heuristic (a scrollable node covering
 *      >= 85% of the screen in a catalogue short-video app).
 * All copy goes through Strings (assets/i18n) with English fallbacks.
 */
class ReelLockController(private val svc: AccessibilityService) {
    private val main = Handler(Looper.getMainLooper())
    private val logic get() = ReelLockLogic(ReelLimits.rules(svc))
    private val trackers = HashMap<String, BounceTracker>()
    private val store = RealCountStore(svc)
    private var lastNotice = 0L
    private var inFeed = ""
    @Volatile var lastLatencyMs = -1L; private set

    private fun catalogue(pkg: String): JSONObject? =
        (CoreConfig.value(svc, "android.social_apps") as? JSONArray)?.let { a ->
            (0 until a.length()).map { a.optJSONObject(it) }.firstOrNull { it?.optString("package") == pkg }
        }

    private fun shortVideo(pkg: String) = catalogue(pkg)?.let { !it.isNull("short_video") } == true

    private fun feedIds(pkg: String): List<String> {
        val out = ArrayList<String>()
        fun add(a: JSONArray?) { if (a != null) for (i in 0 until a.length()) out.add(a.optString(i)) }
        add((CoreConfig.value(svc, "android.realcount.creator.apps") as? JSONObject)?.optJSONObject(pkg)?.optJSONArray("feed_view_ids"))
        add((CoreConfig.value(svc, "android.realcount.feed") as? JSONObject)?.optJSONObject(pkg)?.optJSONArray("view_ids"))
        return out
    }

    private fun used(pkg: String) = store.reels(pkg)

    private fun locked(pkg: String): Boolean {
        val c = ReelLimits.get(svc, pkg)
        if (c.off || !c.hard) return false
        return logic.isLocked(c, used(pkg), ReelLimits.day(svc, logic), pkg)
    }

    // ------------------------------------------------------------------ events (from the service)
    fun onWindow(pkg: String) {
        if (pkg != inFeed) { trackers[inFeed]?.reset(); inFeed = "" }
        if (!locked(pkg)) return
        val at = SystemClock.uptimeMillis()
        main.post { check(pkg, at) }
        main.postDelayed({ check(pkg, at) }, 120)                         // the feed may render a frame later
    }

    fun onClick(pkg: String) {
        if (!locked(pkg)) return
        val at = SystemClock.uptimeMillis()
        main.postDelayed({ check(pkg, at) }, 60)
        main.postDelayed({ check(pkg, at) }, 140)
    }

    /** A scroll in [pkg]: the pager itself scrolling is the fastest feed signal. */
    fun onScroll(pkg: String, e: AccessibilityEvent) {
        if (!locked(pkg)) return
        val src = e.source
        if (src != null && isFeedNode(pkg, src)) bounce(pkg, e.eventTime) else main.post { check(pkg, e.eventTime) }
    }

    /** The counter just counted a reel in [pkg] (RealCountController): deflector / lock. */
    fun onReelCounted(pkg: String) = main.post {
        val c = ReelLimits.get(svc, pkg)
        if (c.off) return@post
        val n = used(pkg)
        val day = ReelLimits.day(svc, logic)
        if (logic.takeDeflector(c, n, day, pkg)) { ReelLimits.saveDay(svc, day); deflect(pkg, n) }
        if (c.hard && logic.isLocked(c, n, day, pkg)) { notice(pkg, n, c); bounce(pkg, SystemClock.uptimeMillis()) }
        else if (!c.hard && n == c.limit) softNotice(pkg, n, c)
    }

    // ------------------------------------------------------------------ feed detection
    private fun screen(): Pair<Int, Int> = svc.resources.displayMetrics.let { it.widthPixels to it.heightPixels }

    private fun isFeedNode(pkg: String, n: AccessibilityNodeInfo): Boolean {
        val ids = feedIds(pkg)
        val id = n.viewIdResourceName ?: ""
        if (ids.isNotEmpty()) return id in ids && n.isVisibleToUser
        if (!shortVideo(pkg)) return false
        val r = Rect(); n.getBoundsInScreen(r)
        val (w, h) = screen()
        return n.isScrollable && n.isVisibleToUser && r.height() >= h * 0.85 && r.width() >= w * 0.9
    }

    private fun feedVisible(pkg: String): Boolean {
        val root = svc.rootInActiveWindow ?: return false
        if (root.packageName?.toString() != pkg) return false
        val ids = feedIds(pkg)
        if (ids.isNotEmpty()) {
            for (id in ids) for (n in root.findAccessibilityNodeInfosByViewId(id)) {
                if (!n.isVisibleToUser) continue
                val r = Rect(); n.getBoundsInScreen(r)
                if (r.height() >= screen().second * 0.6) return true
            }
            return false
        }
        if (!shortVideo(pkg)) return false
        var seen = 0
        fun walk(n: AccessibilityNodeInfo?, d: Int): Boolean {
            if (n == null || d > 10 || seen++ > 250) return false
            if (isFeedNode(pkg, n)) return true
            for (i in 0 until n.childCount) if (walk(n.getChild(i), d + 1)) return true
            return false
        }
        return walk(root, 0)
    }

    private fun check(pkg: String, eventAt: Long) {
        if (!locked(pkg)) return
        if (feedVisible(pkg)) bounce(pkg, eventAt)
        else { trackers[pkg]?.reset(); if (inFeed == pkg) inFeed = "" }
    }

    // ------------------------------------------------------------------ actions
    private fun bounce(pkg: String, eventAt: Long) {
        val c = ReelLimits.get(svc, pkg)
        val t = trackers.getOrPut(pkg) { BounceTracker(logic.rules) }
        inFeed = pkg
        when (t.onFeedVisible(System.currentTimeMillis(), locked(pkg))) {
            BounceAction.BACK -> {
                svc.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)
                lastLatencyMs = SystemClock.uptimeMillis() - eventAt
                notice(pkg, used(pkg), c)
                main.postDelayed({ check(pkg, SystemClock.uptimeMillis()) }, 450)   // still on the feed? Back again / escalate
            }
            BounceAction.ESCALATE -> {
                // the feed survived the Backs: the app's own start screen (not the reels tab), else Home
                val launch = svc.packageManager.getLaunchIntentForPackage(pkg)
                val ok = launch != null && try {
                    svc.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)); true
                } catch (_: Exception) { false }
                if (!ok) svc.performGlobalAction(AccessibilityService.GLOBAL_ACTION_HOME)
                lastLatencyMs = SystemClock.uptimeMillis() - eventAt
            }
            BounceAction.NONE -> {}
        }
    }

    private fun appLabel(pkg: String) = catalogue(pkg)?.optString("label")?.takeIf { it.isNotBlank() }
        ?: try { svc.packageManager.getApplicationLabel(svc.packageManager.getApplicationInfo(pkg, 0)).toString() } catch (_: Exception) { pkg }

    private fun kind(pkg: String) = catalogue(pkg)?.optString("short_video")?.takeIf { it.isNotBlank() && it != "null" } ?: "Reels"

    private fun t(key: String, fallback: String, p: Map<String, String>): String {
        var v = Strings.t(svc, key, p)
        if (v == key) { v = fallback; for ((k, x) in p) v = v.replace("{$k}", x) }
        return v
    }

    /** The lock capsule under the camera + the reel_lock event (once per lock episode, 3 s apart). */
    private fun notice(pkg: String, n: Int, c: ReelLimitConfig) {
        val now = System.currentTimeMillis()
        if (now - lastNotice < 3000) return
        lastNotice = now
        val app = appLabel(pkg)
        val p = mapOf("app" to app, "kind" to kind(pkg), "n" to "$n", "limit" to "${c.limit}")
        var line = t("reel_lock.capsule", "🔒 {app} {kind} locked for today ({n}/{limit}). Everything else in {app} still works.", p)
        val day = ReelLimits.day(svc, logic)
        val grantable = logic.canGrant(c, n, day, pkg)
        if (grantable) line += "  " + t("reel_lock.five_more", "Tap: 5 more after a 10-second breath", p)
        CameraCapsule.status.onTap = if (grantable) ({ breatheThenGrant(pkg) }) else null
        CameraCapsule.status.show(svc, line, CameraCapsule.LOCK, 6000, touchable = grantable)
        CoreBridge.get(svc).publish(JSONObject().put("type", "reel_lock").put("package", pkg).put("n", n).put("limit", c.limit))
    }

    private fun softNotice(pkg: String, n: Int, c: ReelLimitConfig) {
        val p = mapOf("app" to appLabel(pkg), "kind" to kind(pkg), "n" to "$n", "limit" to "${c.limit}")
        CameraCapsule.status.onTap = null
        CameraCapsule.status.show(svc, t("reel_lock.soft_reached", "{n} {kind} — your limit for today.", p), CameraCapsule.AMBER, 4000)
    }

    /** 80%: amber halo on the chip + a 3-second breathing bubble over the next reel. */
    private fun deflect(pkg: String, n: Int) {
        RealCountController.active?.setAppPalette(intArrayOf(CameraCapsule.AMBER, CameraCapsule.LOCK, CameraCapsule.AMBER))
        val text = t("reel_lock.deflector", "{n} {kind} so far. Take a breath.", mapOf("n" to "$n", "kind" to kind(pkg).lowercase()))
        CameraCapsule.status.onTap = null
        CameraCapsule.status.show(svc, text, CameraCapsule.AMBER, logic.rules.deflectBubbleMs.toLong())
    }

    /** "5 more": a 10-second breath countdown under the camera, then the grant (once a day). */
    private fun breatheThenGrant(pkg: String) {
        val s = logic.rules.breathS
        val start = SystemClock.elapsedRealtime()
        CameraCapsule.status.onTap = null
        fun step() {
            val left = s - ((SystemClock.elapsedRealtime() - start) / 1000).toInt()
            if (left > 0) {
                val phase = if ((s - left) % 8 < 4) t("reel_lock.breathe_in", "Breathe in…", emptyMap()) else t("reel_lock.breathe_out", "Breathe out…", emptyMap())
                CameraCapsule.status.show(svc, "$phase $left", CameraCapsule.ACCENT, 1500)
                main.postDelayed({ step() }, 1000)
                return
            }
            val c = ReelLimits.get(svc, pkg)
            val day = ReelLimits.day(svc, logic)
            if (logic.grant(c, used(pkg), day, pkg, SystemClock.elapsedRealtime() - start)) {
                ReelLimits.saveDay(svc, day)
                trackers[pkg]?.reset()
                CameraCapsule.status.show(svc, t("reel_lock.granted", "{extra} more {kind}. Enjoy them mindfully.",
                    mapOf("extra" to "${logic.rules.extraReels}", "kind" to kind(pkg).lowercase())), CameraCapsule.ACCENT, 3000)
            }
        }
        step()
    }

    /** §9 reelLimits row for [pkg]. */
    fun row(pkg: String): JSONObject = rowFor(svc, pkg)

    companion object {
        @Volatile var active: ReelLockController? = null

        fun rowFor(ctx: android.content.Context, pkg: String): JSONObject {
            val logic = ReelLockLogic(ReelLimits.rules(ctx))
            val c = ReelLimits.get(ctx, pkg)
            val used = RealCountStore(ctx).reels(pkg)
            return JSONObject().put("limit", c.limit).put("mode", c.mode).put("used", used)
                .put("state", logic.state(c, used, ReelLimits.day(ctx, logic), pkg))
        }
    }
}
