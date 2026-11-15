package live.snapy.app

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId

/*
 * The nudge engine on the phone: a rule-for-rule PORT of lib/realcount/nudges.dart (the tested
 * reference, test/nudges_test.dart). Same inputs, same order of checks, same i18n keys and
 * once-keys. Pure logic: no views, no Android services. Change both together.
 */

enum class NudgeTrigger { APP_OPENED, REEL_COUNTED, TICK }

enum class NudgeKind { FOCUS_OPEN, INTENTION_DONE, SOFT_LIMIT, SESSION_REELS, FREQUENT_OPENS, BEDTIME }

data class NudgeInput(
    val nowMs: Long,
    val trigger: NudgeTrigger,
    val pkg: String = "",
    val label: String = "",
    val shortVideo: Boolean = false,
    val sessionReels: Int = 0,
    val sessionStartMs: Long = 0,
    val sessionMinutes: Int = 0,
    val opensLastHour: Int = 0,
    val limitFraction: Double = 0.0,
    val inCall: Boolean = false,
    val navigating: Boolean = false,
    val focusUntilMs: Long = 0,
    val intentionEndsMs: Long = 0,
    val intentionId: String? = null,
    val intentionMinutes: Int = 0,
    val voiceOn: Boolean = false,
    val firstTaskTomorrow: String? = null,
)

data class Nudge(
    val kind: NudgeKind,
    val key: String,
    val params: Map<String, String>,
    val actions: List<String>,
    val onceKey: String,
    val soft: Boolean = false,
    val pulse: Boolean = false,
    val speak: Boolean = false,
)

class NudgeState {
    var lastShownMs = 0L
    var dismissals = 0
    var day = ""
    val fired = LinkedHashSet<String>()

    fun toJson(): JSONObject = JSONObject().put("last", lastShownMs).put("dismissals", dismissals).put("day", day)
        .put("fired", JSONArray(fired.toList()))

    companion object {
        fun fromJson(j: JSONObject?): NudgeState {
            val s = NudgeState()
            if (j == null) return s
            s.lastShownMs = j.optLong("last")
            s.dismissals = j.optInt("dismissals")
            s.day = j.optString("day")
            j.optJSONArray("fired")?.let { a -> for (i in 0 until a.length()) s.fired.add(a.optString(i)) }
            return s
        }
    }
}

class NudgeEngine(private val rules: RealCountRules, private val zone: ZoneId = ZoneId.systemDefault()) {

    fun decide(i: NudgeInput, s: NudgeState): Nudge? {
        rollover(i.nowMs, s)
        if (i.inCall || i.navigating) return null                     // never during calls or navigation
        val soft = s.dismissals >= rules.i("nudges.soften_after_dismissals", 2)
        fun k(base: String) = if (soft) "${base}_soft" else base
        val gapOk = i.nowMs - s.lastShownMs >= rules.i("nudges.min_gap_min", 20) * 60000L
        fun fresh(n: Nudge) = if (n.onceKey in s.fired) null else n

        // 1. focus guard (user-requested: exempt from the gap)
        if (i.trigger == NudgeTrigger.APP_OPENED && i.focusUntilMs > 0 && i.nowMs < i.focusUntilMs) {
            fresh(Nudge(NudgeKind.FOCUS_OPEN, k("nudge.focus_open"), mapOf("until" to clock(i.focusUntilMs), "app" to i.label),
                listOf("open_anyway", "back_to_focus"), "focus:${i.pkg}:${i.focusUntilMs}", soft = soft))?.let { return it }
        }
        // 2. intention reminder (user-requested)
        if (i.intentionEndsMs > 0 && i.nowMs >= i.intentionEndsMs && i.intentionId != null) {
            fresh(Nudge(NudgeKind.INTENTION_DONE, k("nudge.intention_done_${i.intentionId}"),
                mapOf("minutes" to "${i.intentionMinutes}", "app" to i.label), listOf("wrap_up", "dismiss"),
                "intent:${i.intentionEndsMs}", soft = soft))?.let { return it }
        }
        if (!gapOk) return null
        // 3. daily soft limit reached
        if (i.limitFraction >= rules.d("chip.amber_at", 1.0) && i.limitFraction > 0) {
            fresh(Nudge(NudgeKind.SOFT_LIMIT, k("nudge.soft_limit"), mapOf("app" to i.label), listOf("reset", "dismiss"),
                "limit:${i.pkg}:${dayKey(i.nowMs)}", soft = soft, pulse = true, speak = i.voiceOn))?.let { return it }
        }
        // 4. a long scroll session
        if (i.shortVideo && i.sessionReels >= rules.i("nudges.session_reels", 30)) {
            fresh(Nudge(NudgeKind.SESSION_REELS, k("nudge.session_reels"),
                mapOf("n" to "${i.sessionReels}", "min" to "${i.sessionMinutes}"), listOf("keep_going", "reset"),
                "session:${i.sessionStartMs}", soft = soft, pulse = true))?.let { return it }
        }
        // 5. coming back again and again
        if (i.trigger == NudgeTrigger.APP_OPENED && i.opensLastHour >= rules.i("nudges.opens_per_hour", 10)) {
            fresh(Nudge(NudgeKind.FREQUENT_OPENS, k("nudge.frequent_opens"),
                mapOf("app" to i.label, "focus" to "${rules.i("nudges.focus_min", 25)}"), listOf("focus", "dismiss"),
                "opens:${i.pkg}:${i.nowMs / 3600000}", soft = soft))?.let { return it }
        }
        // 6. bedtime wind-down while scrolling
        if (i.trigger != NudgeTrigger.TICK && isBedtime(i.nowMs)) {
            val has = !i.firstTaskTomorrow.isNullOrEmpty()
            fresh(Nudge(NudgeKind.BEDTIME, k(if (has) "nudge.bedtime_task" else "nudge.bedtime"),
                if (has) mapOf("task" to i.firstTaskTomorrow!!) else emptyMap(), listOf("wind_down", "dismiss"),
                "bed:${nightKey(i.nowMs)}", soft = soft))?.let { return it }
        }
        return null
    }

    fun pauseBeforeOpen(i: NudgeInput, breakScreen: Boolean): Boolean =
        breakScreen && i.trigger == NudgeTrigger.APP_OPENED && i.limitFraction > 0 &&
            i.limitFraction >= rules.d("chip.amber_at", 1.0) && !i.inCall && !i.navigating

    fun shown(n: Nudge, s: NudgeState, nowMs: Long) {
        rollover(nowMs, s)
        if (n.kind != NudgeKind.FOCUS_OPEN && n.kind != NudgeKind.INTENTION_DONE) s.lastShownMs = nowMs
        s.fired.add(n.onceKey)
        while (s.fired.size > MAX_FIRED) s.fired.remove(s.fired.first())
    }

    fun dismissed(s: NudgeState, nowMs: Long) {
        rollover(nowMs, s)
        s.dismissals++
    }

    fun isBedtime(nowMs: Long): Boolean {
        val bed = rules.minutesOfDay("nudges.bedtime", "23:00")
        val wake = rules.minutesOfDay("nudges.wake", "06:00")
        val t = local(nowMs)
        val m = t.hour * 60 + t.minute
        return if (bed > wake) (m >= bed || m < wake) else (m in bed until wake)
    }

    fun nightKey(nowMs: Long): String {
        val wake = rules.minutesOfDay("nudges.wake", "06:00")
        val t = local(nowMs)
        val d = if (t.hour * 60 + t.minute < wake) t.toLocalDate().minusDays(1) else t.toLocalDate()
        return d.toString()
    }

    private fun rollover(nowMs: Long, s: NudgeState) {
        val d = dayKey(nowMs)
        if (s.day != d) { s.day = d; s.dismissals = 0 }
    }

    private fun local(ms: Long): LocalDateTime = LocalDateTime.ofInstant(Instant.ofEpochMilli(ms), zone)
    fun dayKey(ms: Long): String = local(ms).toLocalDate().toString()                 // YYYY-MM-DD, same as Dart

    /** "4:30" (12-hour, no am/pm), same as Dart clock(). */
    fun clock(ms: Long): String {
        val t = local(ms)
        val h = if (t.hour % 12 == 0) 12 else t.hour % 12
        return "$h:${t.minute.toString().padStart(2, '0')}"
    }

    companion object { const val MAX_FIRED = 100 }
}

/** Opens of each app in the last hour (mirror of OpenTracker). */
class OpenTracker {
    private val opens = HashMap<String, ArrayList<Long>>()
    fun open(pkg: String, nowMs: Long) { opens.getOrPut(pkg) { ArrayList() }.add(nowMs) }
    fun lastHour(pkg: String, nowMs: Long): Int {
        val l = opens[pkg] ?: return 0
        l.removeAll { nowMs - it > 3600000 }
        return l.size
    }
}

/** One scroll session across all short-video apps (mirror of ReelSession). */
class ReelSession {
    var startMs = 0L; var lastMs = 0L; var count = 0
    fun reel(nowMs: Long, gapMs: Long) {
        if (count == 0 || nowMs - lastMs > gapMs) { startMs = nowMs; count = 0 }
        count++
        lastMs = nowMs
    }
    fun minutes(): Int = if (count == 0) 0 else maxOf(1, Math.ceil((lastMs - startMs) / 60000.0).toInt())
    fun active(nowMs: Long, gapMs: Long) = count > 0 && nowMs - lastMs <= gapMs
}

