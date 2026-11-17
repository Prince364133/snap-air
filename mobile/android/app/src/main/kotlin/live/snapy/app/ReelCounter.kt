package live.snapy.app

import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONObject

/*
 * The reel counter's decision — MIRROR of lib/realcount/reel_counter.dart (ReelScroll,
 * ReelCounterRules, ReelCounter); test/reel_counter_test.dart pins the behaviour. Change both.
 * The ONE counting path: RealCountController.onScroll -> ReelCounter.onScroll; the
 * accessibility service only forwards events (no package-name guessing: the catalogue is
 * core rules android.social_apps, the pager ids android.realcount.creator.apps.*.feed_view_ids).
 */

data class ReelScroll(
    val pkg: String,
    val shortVideoApp: Boolean,
    val heightFraction: Double = 0.0,
    val widthFraction: Double = 0.0,
    val sourceId: String = "",
    val windowClass: String = "",
    val fromIndex: Int = -1,
    val toIndex: Int = -1,
    val itemCount: Int = -1,
    val scrollDeltaY: Int = 0,
    val scrollDeltaX: Int = 0,
    val screenHeight: Int = 0,
    val itemKey: String = "",
    val nowMs: Long,
)

data class ReelCounterRules(
    val minDwellMs: Long = 700,
    val minHeightFraction: Double = 0.6,
    val minWidthFraction: Double = 0.9,
    val pageScrollFraction: Double = 0.5,
    val swipeGapMs: Long = 450,
    val feedViewIds: Map<String, List<String>> = emptyMap(),
    val creatorKeywords: List<String> = emptyList(),
    val appKeywords: Map<String, List<String>> = emptyMap(),
) {
    companion object {
        /** From the merged config `android` block (+ the realcount rules overlay). */
        fun from(minDwellMs: Long, realcount: JSONObject?): ReelCounterRules {
            val det = realcount?.optJSONObject("reel_detection")
            val creator = realcount?.optJSONObject("creator")
            val apps = creator?.optJSONObject("apps")
            fun strs(o: JSONObject?, k: String): List<String> =
                o?.optJSONArray(k)?.let { a -> (0 until a.length()).map { a.optString(it) } } ?: emptyList()
            val ids = HashMap<String, List<String>>(); val kw = HashMap<String, List<String>>()
            apps?.keys()?.forEach { p -> ids[p] = strs(apps.optJSONObject(p), "feed_view_ids"); kw[p] = strs(apps.optJSONObject(p), "keywords") }
            return ReelCounterRules(
                minDwellMs = minDwellMs,
                minHeightFraction = det?.optDouble("feed_min_height_fraction", 0.6) ?: 0.6,
                minWidthFraction = det?.optDouble("feed_min_width_fraction", 0.9) ?: 0.9,
                pageScrollFraction = det?.optDouble("page_scroll_fraction", 0.5) ?: 0.5,
                swipeGapMs = det?.optLong("swipe_gap_ms", 450L) ?: 450L,
                feedViewIds = ids,
                creatorKeywords = strs(creator, "keywords"),
                appKeywords = kw,
            )
        }
    }
}

enum class ReelDecision { NOT_FEED, SAME_ITEM, FLICK, COUNTED }

class ReelCounter(@Volatile var rules: ReelCounterRules = ReelCounterRules()) {
    private class Feed { var lastIndex = -1; var lastKey = ""; var shownAt = 0L; var lastEventAt: Long? = null; var burstCounted = false }
    private val feeds = HashMap<String, Feed>()

    fun reset(pkg: String? = null) { if (pkg == null) feeds.clear() else feeds.remove(pkg) }

    fun isFeed(e: ReelScroll): Boolean {
        if (!e.shortVideoApp) return false
        if (e.heightFraction > 0 && e.heightFraction < rules.minHeightFraction) return false
        if (e.widthFraction > 0 && e.widthFraction < rules.minWidthFraction) return false
        val ids = rules.feedViewIds[e.pkg] ?: emptyList()
        val isKnownId = if (ids.isNotEmpty() && e.sourceId.isNotEmpty()) {
            val simpleId = e.sourceId.substringAfterLast(":id/").substringAfterLast('/')
            ids.any { id ->
                val simpleRuleId = id.substringAfterLast(":id/").substringAfterLast('/')
                e.sourceId.equals(id, ignoreCase = true) || simpleId.equals(simpleRuleId, ignoreCase = true)
            } || simpleId.contains("clips") || simpleId.contains("reel")
        } else false
        if (ids.isNotEmpty() && e.sourceId.isNotEmpty() && !isKnownId) return false
        val maxSpread = if (isKnownId) 4 else 1
        if (e.fromIndex >= 0 && e.toIndex >= 0 && e.toIndex - e.fromIndex > maxSpread) return false
        if (kotlin.math.abs(e.scrollDeltaX) > kotlin.math.abs(e.scrollDeltaY)) return false   // sideways: camera / DMs
        val hay = "${e.windowClass.lowercase()} ${e.sourceId.lowercase()}"
        return (rules.creatorKeywords + (rules.appKeywords[e.pkg] ?: emptyList())).none { it.isNotEmpty() && hay.contains(it.lowercase()) }
    }

    fun onScroll(e: ReelScroll): ReelDecision {
        if (!isFeed(e)) return ReelDecision.NOT_FEED
        // a new run: the reel showing when the user opened the feed counts at the first swipe
        val f = feeds.getOrPut(e.pkg) { Feed().also { it.shownAt = e.nowMs - rules.minDwellMs } }
        val last = f.lastEventAt
        val quiet = last == null || e.nowMs - last >= rules.swipeGapMs
        f.lastEventAt = e.nowMs
        val changed: Boolean
        if (e.fromIndex >= 0 && e.itemCount > 1) {
            changed = f.lastIndex >= 0 && f.lastIndex != e.fromIndex
            val first = f.lastIndex < 0
            f.lastIndex = e.fromIndex
            if (e.itemKey.isNotEmpty()) f.lastKey = e.itemKey
            if (first) { f.shownAt = e.nowMs; return ReelDecision.SAME_ITEM }
        } else {
            // Instagram's ViewPager2: -1 indices, deltaY 0, and the same Like/Comment/Share labels on
            // every reel (the identity hash never changes) -> one swipe = one burst of events
            if (e.heightFraction <= 0) return ReelDecision.SAME_ITEM          // size unknown: maybe a ticker
            if (quiet) f.burstCounted = false
            val keyChanged = e.itemKey.isNotEmpty() && f.lastKey.isNotEmpty() && f.lastKey != e.itemKey
            if (e.itemKey.isNotEmpty()) f.lastKey = e.itemKey
            val pageSized = e.screenHeight > 0 && kotlin.math.abs(e.scrollDeltaY) >= e.screenHeight * rules.pageScrollFraction
            changed = !f.burstCounted && (quiet || keyChanged || pageSized)
            if (changed) f.burstCounted = true
        }
        if (!changed) return ReelDecision.SAME_ITEM
        val dwelled = e.nowMs - f.shownAt
        f.shownAt = e.nowMs
        return if (dwelled >= rules.minDwellMs) ReelDecision.COUNTED else ReelDecision.FLICK
    }

    companion object {
        /** Identity of the pager's visible item: text/descriptions of the child covering the
         *  screen centre (caption, author, "Reel by …"). Content is hashed, never stored or logged. */
        fun itemKey(pager: AccessibilityNodeInfo?, screenW: Int, screenH: Int): String {
            if (pager == null) return ""
            return try {
                val r = Rect()
                var visible: AccessibilityNodeInfo? = null
                for (i in 0 until minOf(pager.childCount, 6)) {
                    val c = pager.getChild(i) ?: continue
                    c.getBoundsInScreen(r)
                    if (r.contains(screenW / 2, screenH / 2)) { visible = c; break }
                }
                val node = visible ?: return ""
                val parts = ArrayList<String>()
                fun walk(n: AccessibilityNodeInfo?, d: Int) {
                    if (n == null || d > 5 || parts.size >= 8) return
                    val t = (n.contentDescription ?: n.text)?.toString()?.trim().orEmpty()
                    if (t.isNotEmpty() && t.length < 400 && t.any { it.isLetter() }) parts.add(t)
                    for (i in 0 until minOf(n.childCount, 12)) walk(n.getChild(i), d + 1)
                }
                walk(node, 0)
                if (parts.isEmpty()) "" else Integer.toHexString(parts.joinToString("\u0001").hashCode())
            } catch (_: Exception) { "" }
        }
    }
}

/**
 * The last scroll events the counter saw and what it decided, for Settings -> Diagnostics, so a
 * miss on a real phone can be diagnosed from facts, not guesses. Only package, view id, sizes,
 * indices and the decision: never text, captions or what was on screen. In memory only.
 */
object ReelDebug {
    private const val KEEP = 60
    private val lines = ArrayDeque<String>()

    @Synchronized fun add(e: ReelScroll, outcome: String) {
        val t = java.text.SimpleDateFormat("HH:mm:ss.SSS", java.util.Locale.US).format(java.util.Date(e.nowMs))
        lines.addLast("$t ${e.pkg} id=${e.sourceId.substringAfter(":id/").ifEmpty { "-" }} " +
            "h=${"%.2f".format(java.util.Locale.US, e.heightFraction)} w=${"%.2f".format(java.util.Locale.US, e.widthFraction)} " +
            "idx=${e.fromIndex}..${e.toIndex}/${e.itemCount} dy=${e.scrollDeltaY} dx=${e.scrollDeltaX} " +
            "key=${if (e.itemKey.isEmpty()) "-" else "y"} cls=${e.windowClass.substringAfterLast('.').ifEmpty { "-" }} -> $outcome")
        while (lines.size > KEEP) lines.removeFirst()
    }

    @Synchronized fun dump(): String = lines.joinToString("\n")
}
