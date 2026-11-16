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
    val screenHeight: Int = 0,
    val itemKey: String = "",
    val nowMs: Long,
)

data class ReelCounterRules(
    val minDwellMs: Long = 700,
    val minHeightFraction: Double = 0.6,
    val minWidthFraction: Double = 0.9,
    val pageScrollFraction: Double = 0.5,
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
                feedViewIds = ids,
                creatorKeywords = strs(creator, "keywords"),
                appKeywords = kw,
            )
        }
    }
}

enum class ReelDecision { NOT_FEED, SAME_ITEM, FLICK, COUNTED }

class ReelCounter(@Volatile var rules: ReelCounterRules = ReelCounterRules()) {
    private class Feed { var lastIndex = -1; var lastKey = ""; var shownAt = 0L }
    private val feeds = HashMap<String, Feed>()

    fun reset(pkg: String? = null) { if (pkg == null) feeds.clear() else feeds.remove(pkg) }

    fun isFeed(e: ReelScroll): Boolean {
        if (!e.shortVideoApp) return false
        if (e.heightFraction > 0 && e.heightFraction < rules.minHeightFraction) return false
        if (e.widthFraction > 0 && e.widthFraction < rules.minWidthFraction) return false
        val ids = rules.feedViewIds[e.pkg] ?: emptyList()
        if (ids.isNotEmpty() && e.sourceId.isNotEmpty() && e.sourceId !in ids) return false
        if (e.fromIndex >= 0 && e.toIndex >= 0 && e.toIndex - e.fromIndex > 1) return false
        val hay = "${e.windowClass.lowercase()} ${e.sourceId.lowercase()}"
        return (rules.creatorKeywords + (rules.appKeywords[e.pkg] ?: emptyList())).none { it.isNotEmpty() && hay.contains(it.lowercase()) }
    }

    fun onScroll(e: ReelScroll): ReelDecision {
        if (!isFeed(e)) return ReelDecision.NOT_FEED
        val f = feeds.getOrPut(e.pkg) { Feed().also { it.shownAt = e.nowMs } }
        val changed: Boolean
        if (e.fromIndex >= 0 && e.itemCount > 1) {
            changed = f.lastIndex >= 0 && f.lastIndex != e.fromIndex
            val first = f.lastIndex < 0
            f.lastIndex = e.fromIndex
            if (e.itemKey.isNotEmpty()) f.lastKey = e.itemKey
            if (first) { f.shownAt = e.nowMs; return ReelDecision.SAME_ITEM }
        } else if (e.itemKey.isNotEmpty()) {
            changed = f.lastKey.isNotEmpty() && f.lastKey != e.itemKey
            val first = f.lastKey.isEmpty()
            f.lastKey = e.itemKey
            if (first) { f.shownAt = e.nowMs; return ReelDecision.SAME_ITEM }
        } else {
            changed = e.screenHeight > 0 && kotlin.math.abs(e.scrollDeltaY) >= e.screenHeight * rules.pageScrollFraction
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
