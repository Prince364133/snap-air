package live.snapy.app

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.os.Process
import java.time.LocalDate
import java.time.ZoneId

/**
 * Screen time today from Android's usage events — the same source Digital Wellbeing uses.
 * Foreground time per app = RESUMED -> PAUSED/STOPPED intervals (screen-off ends a session).
 */
class UsageTracker(private val ctx: Context) {
    data class Today(val totalMs: Long, val perApp: Map<String, Long>, val opens: Map<String, Int>)

    private val usm = ctx.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager

    fun hasAccess(): Boolean {
        val ops = ctx.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), ctx.packageName)
        return mode == AppOpsManager.MODE_ALLOWED
    }

    /** The home screen isn't "using the phone" (Digital Wellbeing excludes it too). */
    private val launchers: Set<String> by lazy {
        val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        ctx.packageManager.queryIntentActivities(home, 0).map { it.activityInfo.packageName }.toSet()
    }

    fun today(): Today {
        if (!hasAccess()) return Today(0, emptyMap(), emptyMap())
        val start = LocalDate.now().atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val now = System.currentTimeMillis()
        val events = try { usm.queryEvents(start, now) } catch (t: Throwable) { null }
        if (events == null) return Today(0, emptyMap(), emptyMap())
        val e = UsageEvents.Event()
        val perApp = HashMap<String, Long>()
        val opens = HashMap<String, Int>()
        var fgPkg: String? = null
        var fgSince = 0L

        fun close(at: Long) {
            val p = fgPkg ?: return
            if (p !in launchers) perApp[p] = (perApp[p] ?: 0L) + (at - fgSince).coerceAtLeast(0)
            fgPkg = null
        }

        try {
            while (events.hasNextEvent()) {
                events.getNextEvent(e)
                when (e.eventType) {
                    UsageEvents.Event.ACTIVITY_RESUMED -> {
                        if (fgPkg != e.packageName) {
                            close(e.timeStamp)
                            fgPkg = e.packageName
                            fgSince = e.timeStamp
                            if (e.packageName !in launchers) opens[e.packageName] = (opens[e.packageName] ?: 0) + 1
                        }
                    }
                    UsageEvents.Event.ACTIVITY_PAUSED, UsageEvents.Event.ACTIVITY_STOPPED ->
                        if (e.packageName == fgPkg) close(e.timeStamp)
                    UsageEvents.Event.SCREEN_NON_INTERACTIVE, UsageEvents.Event.KEYGUARD_SHOWN -> close(e.timeStamp)
                }
            }
            close(now)                              // the app open right now counts until now
        } catch (t: Throwable) {
            android.util.Log.e("UsageTracker", "Error reading usage events", t)
        }
        return Today(perApp.values.sum(), perApp, opens)
    }

    /** The app in front right now (last RESUMED in the past 10 min), for the chip without accessibility. */
    fun foreground(): String? {
        if (!hasAccess()) return null
        val now = System.currentTimeMillis()
        val events = try { usm.queryEvents(now - 10 * 60_000, now) } catch (t: Throwable) { null }
        if (events == null) return null
        val e = UsageEvents.Event()
        var pkg: String? = null
        try {
            while (events.hasNextEvent()) {
                events.getNextEvent(e)
                if (e.eventType == UsageEvents.Event.ACTIVITY_RESUMED) pkg = e.packageName
            }
        } catch (t: Throwable) {
            android.util.Log.e("UsageTracker", "Error reading foreground events", t)
        }
        return pkg?.takeIf { it !in launchers } ?: pkg?.let { "" }
    }

    companion object {
        fun format(ms: Long): String {
            val m = ms / 60000
            return if (m >= 60) "${m / 60}h ${m % 60}m" else "${m}m"
        }
    }
}
