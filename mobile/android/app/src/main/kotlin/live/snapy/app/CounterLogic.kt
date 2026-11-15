package live.snapy.app

import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.max

/*
 * Pure Real Count logic (no Android views) — a line-by-line PORT of the Dart reference:
 *   lib/realcount/rules.dart       -> RealCountRules
 *   lib/realcount/chip_logic.dart  -> ChipLogic
 * The Dart side is unit-tested (test/chip_logic_test.dart); keep both in step.
 */

/** Merged rules: bundled assets/rules/realcount.json < config android.realcount < signed cache. */
class RealCountRules(val raw: JSONObject) {
    fun get(dotted: String): Any? {
        var v: Any? = raw
        for (k in dotted.split('.')) v = (v as? JSONObject)?.opt(k) ?: return null
        return if (v == JSONObject.NULL) null else v
    }
    fun i(dotted: String, def: Int): Int = (get(dotted) as? Number)?.toInt() ?: def
    fun d(dotted: String, def: Double): Double = (get(dotted) as? Number)?.toDouble() ?: def
    fun s(dotted: String, def: String): String = get(dotted)?.toString() ?: def
    fun b(dotted: String, def: Boolean): Boolean = (get(dotted) as? Boolean) ?: def
    fun list(dotted: String): List<String> = (get(dotted) as? JSONArray)?.let { a -> (0 until a.length()).map { a.optString(it) } } ?: emptyList()
    fun minutesOfDay(dotted: String, def: String) = parseHm(s(dotted, def))

    companion object {
        fun parseHm(hm: String): Int {
            val p = hm.split(':')
            val h = p.getOrNull(0)?.trim()?.toIntOrNull() ?: 0
            val m = p.getOrNull(1)?.trim()?.toIntOrNull() ?: 0
            return h.coerceIn(0, 23) * 60 + m.coerceIn(0, 59)
        }

        fun deepMerge(base: JSONObject, over: JSONObject?): JSONObject {
            val out = JSONObject(base.toString())
            if (over == null) return out
            for (k in over.keys()) {
                val a = out.opt(k)
                val b = over.opt(k)
                out.put(k, if (a is JSONObject && b is JSONObject) deepMerge(a, b) else b)
            }
            return out
        }
    }
}

data class CutRect(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val width get() = right - left
    val height get() = bottom - top
    val centerX get() = (left + right) / 2
    val centerY get() = (top + bottom) / 2
}

data class ChipPlacement(val x: Int, val y: Int, val cameraGap: Int, val height: Int)

enum class ChipTone { NORMAL, AMBER, DIM, PAUSED }

object ChipLogic {
    fun formatDuration(ms: Long): String {
        val m = ms / 60000
        return if (m >= 60) "${m / 60}h ${m % 60}m" else "${m}m"
    }

    fun limitFraction(usedMs: Long, limitMin: Int, reels: Int, reelLimit: Int): Double {
        var f = 0.0
        if (limitMin > 0) f = max(f, usedMs.toDouble() / (limitMin * 60000.0))
        if (reelLimit > 0) f = max(f, reels.toDouble() / reelLimit)
        return f
    }

    fun tone(fraction: Double, amberAt: Double, bedtime: Boolean, paused: Boolean): ChipTone = when {
        paused -> ChipTone.PAUSED
        fraction > 0 && fraction >= amberAt -> ChipTone.AMBER      // amber, never red
        bedtime -> ChipTone.DIM
        else -> ChipTone.NORMAL
    }

    fun ring(fraction: Double): Float = if (fraction.isNaN()) 0f else fraction.coerceIn(0.0, 1.0).toFloat()

    /** Mirror of placeChip() in chip_logic.dart. */
    fun place(screenW: Int, statusBarH: Int, chipW: Int, chipH: Int, cutouts: List<CutRect>, gapPadPx: Int,
              wideFraction: Double, saved: Pair<Int, Int>?): ChipPlacement {
        fun clampX(x: Int, w: Int) = x.coerceIn(0, max(0, screenW - w))
        if (saved != null) return ChipPlacement(clampX(saved.first, chipW), max(0, saved.second), 0, chipH)
        val top = cutouts.filter { it.top < max(statusBarH, chipH * 2) }.sortedBy { it.top }
        if (top.isEmpty()) return ChipPlacement(clampX((screenW - chipW) / 2, chipW), max(0, (statusBarH - chipH) / 2), 0, chipH)
        val c = top.first()
        if (c.width > screenW * wideFraction) return ChipPlacement(clampX((screenW - chipW) / 2, chipW), c.bottom + gapPadPx, 0, chipH)
        val gap = c.width + 2 * gapPadPx
        val w = chipW + gap
        val h = max(chipH, c.height + gapPadPx)
        return ChipPlacement(clampX(c.centerX - w / 2, w), max(0, c.centerY - h / 2), gap, h)
    }

    fun hidden(fullscreen: Boolean, game: Boolean, locked: Boolean, inCall: Boolean, userHidden: Boolean,
               hiddenToday: Boolean, hiddenForNow: Boolean, listening: Boolean): Boolean {
        if (locked || userHidden) return true
        if (listening) return false
        return fullscreen || game || inCall || hiddenToday || hiddenForNow
    }

    fun counterPaused(nowMs: Long, inAppSinceMs: Long, lastEventMs: Long, staleAfterMs: Long): Boolean {
        if (inAppSinceMs <= 0) return false
        return nowMs - max(inAppSinceMs, lastEventMs) >= staleAfterMs
    }

    /** Creator mode: only feed scrolls count (mirror of countsAsFeed). */
    fun countsAsFeed(rules: RealCountRules, pkg: String, windowClass: String, sourceId: String, creatorMode: Boolean): Boolean {
        if (!creatorMode) return true
        val app = (rules.get("creator.apps") as? JSONObject)?.optJSONObject(pkg)     // packages contain dots
        val feedIds = app?.optJSONArray("feed_view_ids")?.let { a -> (0 until a.length()).map { a.optString(it) } } ?: emptyList()
        if (feedIds.isNotEmpty() && sourceId.isNotEmpty()) return sourceId in feedIds
        val words = HashSet(rules.list("creator.keywords"))
        app?.optJSONArray("keywords")?.let { a -> for (i in 0 until a.length()) words.add(a.optString(i)) }
        val hay = "${windowClass.lowercase()} ${sourceId.lowercase()}"
        return words.none { it.isNotEmpty() && hay.contains(it.lowercase()) }
    }

    data class Intention(val id: String, val minutes: Int)

    fun intentionOptions(rules: RealCountRules): List<Intention> {
        val a = rules.get("intention.options") as? JSONArray ?: return emptyList()
        return (0 until a.length()).mapNotNull { a.optJSONObject(it) }.filter { it.has("id") }
            .map { Intention(it.optString("id"), it.optInt("minutes", 10)) }
    }

    fun shouldAskIntention(rules: RealCountRules, nowMs: Long, lastAskedMs: Long, enabled: Boolean, focusOn: Boolean, planRunning: Boolean): Boolean {
        if (!enabled || !rules.b("intention.enabled", true) || focusOn || planRunning) return false
        return nowMs - lastAskedMs >= rules.i("intention.ask_cooldown_min", 30) * 60000L
    }

}
