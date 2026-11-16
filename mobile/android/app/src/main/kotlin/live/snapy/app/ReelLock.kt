package live.snapy.app

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

/*
 * Reel limits and the hard lock (docs/ANDROID_NEXT_PLAN.md §3).
 *
 * MIRROR of lib/realcount/reel_lock.dart (ReelLockRules, ReelLimitConfig, ReelDay, ReelLock,
 * BounceTracker) — same names, same defaults, same decisions; test/reel_lock_test.dart pins
 * the behaviour (like CounterLogic.kt <-> chip_logic.dart). Change both together.
 *
 * Storage (device-only, never synced):
 *   - the per-app {limit, mode} lives in the core runtime's settings (`reel_limits`) and is
 *     mirrored here in RcPrefs "rl_limits" so the accessibility service reads it synchronously
 *     (the bounce must happen within 150 ms of feed detection);
 *   - the day's bookkeeping ("5 more" grants, deflector shown) is RcPrefs "s_rl_day".
 */

data class ReelLockRules(
    val extraReels: Int = 5,
    val extraPerDay: Int = 1,
    val breathS: Int = 10,
    val deflectAt: Double = 0.8,
    val deflectBubbleMs: Int = 3000,
    val maxBacks: Int = 2,
    val bounceWindowMs: Int = 2500,
    val bounceLatencyMs: Int = 150,
) {
    companion object {
        fun fromJson(j: JSONObject?): ReelLockRules {
            val d = ReelLockRules()
            if (j == null) return d
            return ReelLockRules(
                extraReels = j.optInt("extra_reels", d.extraReels),
                extraPerDay = j.optInt("extra_per_day", d.extraPerDay),
                breathS = j.optInt("breath_s", d.breathS),
                deflectAt = j.optDouble("deflect_at", d.deflectAt),
                deflectBubbleMs = j.optInt("deflect_bubble_ms", d.deflectBubbleMs),
                maxBacks = j.optInt("max_backs", d.maxBacks),
                bounceWindowMs = j.optInt("bounce_window_ms", d.bounceWindowMs),
                bounceLatencyMs = j.optInt("bounce_latency_ms", d.bounceLatencyMs),
            )
        }
    }
}

data class ReelLimitConfig(val limit: Int = 0, val mode: String = "soft") {
    val hard get() = mode == "hard"
    val off get() = limit <= 0

    fun toJson(): JSONObject = JSONObject().put("limit", limit).put("mode", mode)

    companion object {
        fun fromJson(j: JSONObject?) = ReelLimitConfig(
            (j?.optInt("limit", 0) ?: 0).coerceIn(0, 100000),
            if (j?.optString("mode") == "hard") "hard" else "soft",
        )
    }
}

object ReelLockState {
    const val OFF = "off"; const val OK = "ok"; const val NEAR = "near"; const val OVER = "over"
    const val LOCKED = "locked"; const val UNLOCKED = "unlocked"
}

class ReelDay(var day: String, val grants: HashMap<String, Int> = HashMap(), val deflected: HashSet<String> = HashSet()) {
    fun toJson(): JSONObject = JSONObject().put("day", day)
        .put("grants", JSONObject(grants as Map<*, *>))
        .put("deflected", JSONArray(deflected.sorted()))

    companion object {
        fun fromJson(j: JSONObject?): ReelDay {
            val d = ReelDay(j?.optString("day", "") ?: "")
            j?.optJSONObject("grants")?.let { g -> g.keys().forEach { d.grants[it] = g.optInt(it) } }
            j?.optJSONArray("deflected")?.let { a -> for (i in 0 until a.length()) d.deflected.add(a.optString(i)) }
            return d
        }
    }
}

class ReelLockLogic(val rules: ReelLockRules = ReelLockRules()) {
    fun rollover(d: ReelDay, nowMs: Long): ReelDay {
        val k = dayKey(nowMs)
        return if (d.day == k) d else ReelDay(k)
    }

    fun allowance(c: ReelLimitConfig, d: ReelDay, pkg: String) = c.limit + (d.grants[pkg] ?: 0) * rules.extraReels

    fun nearAt(c: ReelLimitConfig): Int = maxOf(1, kotlin.math.ceil(c.limit * rules.deflectAt).toInt())

    fun state(c: ReelLimitConfig, used: Int, d: ReelDay, pkg: String): String {
        if (c.off) return ReelLockState.OFF
        val grants = d.grants[pkg] ?: 0
        if (c.hard) {
            if (used >= allowance(c, d, pkg)) return ReelLockState.LOCKED
            if (grants > 0 && used >= c.limit) return ReelLockState.UNLOCKED
        } else if (used >= c.limit) return ReelLockState.OVER
        if (used >= nearAt(c)) return ReelLockState.NEAR
        return ReelLockState.OK
    }

    fun isLocked(c: ReelLimitConfig, used: Int, d: ReelDay, pkg: String) = state(c, used, d, pkg) == ReelLockState.LOCKED

    /** Once per app per day, between 80% and the limit. Marks it shown when true. */
    fun takeDeflector(c: ReelLimitConfig, used: Int, d: ReelDay, pkg: String): Boolean {
        if (c.off || d.deflected.contains(pkg)) return false
        if (used < nearAt(c) || used >= c.limit) return false
        d.deflected.add(pkg)
        return true
    }

    fun canGrant(c: ReelLimitConfig, used: Int, d: ReelDay, pkg: String) =
        isLocked(c, used, d, pkg) && (d.grants[pkg] ?: 0) < rules.extraPerDay

    fun grant(c: ReelLimitConfig, used: Int, d: ReelDay, pkg: String, breathedMs: Long): Boolean {
        if (!canGrant(c, used, d, pkg) || breathedMs < rules.breathS * 1000L) return false
        d.grants[pkg] = (d.grants[pkg] ?: 0) + 1
        return true
    }

    companion object {
        fun dayKey(ms: Long): String {
            val c = Calendar.getInstance().apply { timeInMillis = ms }
            return String.format(java.util.Locale.US, "%04d-%02d-%02d", c.get(Calendar.YEAR), c.get(Calendar.MONTH) + 1, c.get(Calendar.DAY_OF_MONTH))
        }
    }
}

enum class BounceAction { NONE, BACK, ESCALATE }

class BounceTracker(private val rules: ReelLockRules = ReelLockRules()) {
    private val backs = ArrayList<Long>()

    fun onFeedVisible(nowMs: Long, locked: Boolean): BounceAction {
        if (!locked) { backs.clear(); return BounceAction.NONE }
        backs.removeAll { nowMs - it > rules.bounceWindowMs }
        if (backs.size >= rules.maxBacks) { backs.clear(); return BounceAction.ESCALATE }
        backs.add(nowMs)
        return BounceAction.BACK
    }

    fun reset() = backs.clear()
    val recentBacks get() = backs.size
}

/** The device-only store of limits + the day state (RcPrefs), cached for the hot path. */
object ReelLimits {
    private const val KEY = "rl_limits"
    private const val DAY = "s_rl_day"
    @Volatile private var cache: Map<String, ReelLimitConfig>? = null
    @Volatile private var dayCache: ReelDay? = null

    fun all(ctx: Context): Map<String, ReelLimitConfig> = cache ?: synchronized(this) {
        cache ?: parse(RcPrefs(ctx).str(KEY, "{}")).also { cache = it }
    }

    fun get(ctx: Context, pkg: String): ReelLimitConfig = all(ctx)[pkg] ?: ReelLimitConfig()

    private fun parse(text: String): Map<String, ReelLimitConfig> = try {
        val o = JSONObject(text)
        o.keys().asSequence().associateWith { ReelLimitConfig.fromJson(o.optJSONObject(it)) }.filterValues { !it.off }
    } catch (_: Exception) { emptyMap() }

    fun set(ctx: Context, pkg: String, limit: Int, mode: String) = synchronized(this) {
        val m = HashMap(all(ctx))
        if (limit <= 0) m.remove(pkg) else m[pkg] = ReelLimitConfig(limit, if (mode == "hard") "hard" else "soft")
        save(ctx, m)
    }

    /** The runtime's `reel_limits` (source of truth) -> the mirror. */
    fun replaceAll(ctx: Context, json: JSONObject) = synchronized(this) { save(ctx, parse(json.toString())) }

    private fun save(ctx: Context, m: Map<String, ReelLimitConfig>) {
        val o = JSONObject(); m.forEach { (k, v) -> o.put(k, v.toJson()) }
        RcPrefs(ctx).putString(KEY, o.toString())
        cache = m
    }

    fun day(ctx: Context, logic: ReelLockLogic, nowMs: Long = System.currentTimeMillis()): ReelDay = synchronized(this) {
        val d = dayCache ?: ReelDay.fromJson(try { JSONObject(RcPrefs(ctx).str(DAY, "{}")) } catch (_: Exception) { null })
        val r = logic.rollover(d, nowMs)                              // midnight reset
        if (r !== d) saveDay(ctx, r)
        dayCache = r
        r
    }

    fun saveDay(ctx: Context, d: ReelDay) = synchronized(this) {
        dayCache = d
        RcPrefs(ctx).putString(DAY, d.toJson().toString())
    }

    fun rules(ctx: Context): ReelLockRules =
        ReelLockRules.fromJson(CoreConfig.value(ctx, "android.realcount.reel_lock") as? JSONObject)
}
