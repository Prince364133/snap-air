package live.snapy.app

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Process
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.TemporalAdjusters

/**
 * Screen time from Android's authoritative UsageStatsManager — matching Digital Wellbeing exactly.
 * Real per-app foreground time, genuine app labels, and per-day weekly history.
 */
class UsageTracker(private val ctx: Context) {
    data class Today(
        val totalMs: Long,
        val perApp: Map<String, Long>,
        val opens: Map<String, Int>,
        val labels: Map<String, String> = emptyMap(),
    )

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
        if (!hasAccess()) return Today(0, emptyMap(), emptyMap(), emptyMap())
        val start = LocalDate.now().atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val now = System.currentTimeMillis()
        val pm = ctx.packageManager

        val perApp = HashMap<String, Long>()
        val opens = HashMap<String, Int>()
        val labels = HashMap<String, String>()

        // 1. Authoritative per-app foreground time aggregated by Android OS (exact Digital Wellbeing source)
        val stats = try {
            usm.queryAndAggregateUsageStats(start, now)
        } catch (t: Throwable) {
            android.util.Log.e("UsageTracker", "queryAndAggregateUsageStats failed", t)
            null
        }

        if (!stats.isNullOrEmpty()) {
            stats.forEach { (pkg, usageStats) ->
                if (pkg !in launchers && pkg != "com.android.systemui" && !pkg.contains("inputmethod")) {
                    val ms = usageStats.totalTimeInForeground
                    if (ms > 0) {
                        perApp[pkg] = ms
                    }
                }
            }
        }

        // 2. Query usage events to get exact launch counts and fill in if stats were empty
        try {
            val events = usm.queryEvents(start, now)
            if (events != null) {
                val e = UsageEvents.Event()
                var lastResumed = ""
                var fgPkg: String? = null
                var fgSince = 0L

                while (events.hasNextEvent()) {
                    events.getNextEvent(e)
                    when (e.eventType) {
                        UsageEvents.Event.ACTIVITY_RESUMED -> {
                            if (e.packageName != lastResumed && e.packageName !in launchers && e.packageName != "com.android.systemui") {
                                opens[e.packageName] = (opens[e.packageName] ?: 0) + 1
                                lastResumed = e.packageName
                            }
                            if (perApp.isEmpty()) {
                                if (fgPkg != e.packageName) {
                                    if (fgPkg != null && fgPkg !in launchers) {
                                        perApp[fgPkg!!] = (perApp[fgPkg!!] ?: 0L) + (e.timeStamp - fgSince).coerceAtLeast(0)
                                    }
                                    fgPkg = e.packageName
                                    fgSince = e.timeStamp
                                }
                            }
                        }
                        UsageEvents.Event.ACTIVITY_PAUSED, UsageEvents.Event.ACTIVITY_STOPPED -> {
                            if (perApp.isEmpty() && e.packageName == fgPkg) {
                                if (fgPkg !in launchers) {
                                    perApp[fgPkg!!] = (perApp[fgPkg!!] ?: 0L) + (e.timeStamp - fgSince).coerceAtLeast(0)
                                }
                                fgPkg = null
                            }
                        }
                        UsageEvents.Event.SCREEN_NON_INTERACTIVE, UsageEvents.Event.KEYGUARD_SHOWN -> {
                            if (perApp.isEmpty() && fgPkg != null) {
                                if (fgPkg !in launchers) {
                                    perApp[fgPkg!!] = (perApp[fgPkg!!] ?: 0L) + (e.timeStamp - fgSince).coerceAtLeast(0)
                                }
                                fgPkg = null
                            }
                        }
                    }
                }
                if (perApp.isEmpty() && fgPkg != null && fgPkg !in launchers) {
                    perApp[fgPkg!!] = (perApp[fgPkg!!] ?: 0L) + (now - fgSince).coerceAtLeast(0)
                }
            }
        } catch (t: Throwable) {
            android.util.Log.e("UsageTracker", "Error reading events for opens", t)
        }

        // 3. Resolve genuine application labels dynamically from Android PackageManager for all installed apps
        val installedLabels = HashMap<String, String>()
        try {
            val installed = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                pm.getInstalledApplications(android.content.pm.PackageManager.ApplicationInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                pm.getInstalledApplications(0)
            }
            for (app in installed) {
                try {
                    installedLabels[app.packageName] = pm.getApplicationLabel(app).toString()
                } catch (_: Throwable) {}
            }
        } catch (t: Throwable) {
            android.util.Log.w("UsageTracker", "Could not bulk-query installed applications", t)
        }

        for (pkg in perApp.keys) {
            var label = installedLabels[pkg]
            if (label.isNullOrEmpty()) {
                try {
                    val ai = pm.getApplicationInfo(pkg, 0)
                    label = pm.getApplicationLabel(ai).toString()
                } catch (_: Throwable) {
                    try {
                        val launchIntent = pm.getLaunchIntentForPackage(pkg)
                        if (launchIntent != null) {
                            val ri = pm.resolveActivity(launchIntent, 0)
                            if (ri != null) {
                                label = ri.loadLabel(pm).toString()
                            }
                        }
                    } catch (_: Throwable) {}
                }
            }
            // Clean dynamic fallback if app was uninstalled or system internal (zero hardcoding)
            if (label.isNullOrBlank()) {
                val lastPart = pkg.substringAfterLast('.')
                label = if (lastPart.isNotEmpty()) {
                    lastPart.replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() }
                } else pkg
            }
            labels[pkg] = label
        }

        val totalMs = perApp.values.sum()
        return Today(totalMs, perApp, opens, labels)
    }

    /**
     * Daily screen time in milliseconds for Monday..Sunday of the requested week.
     * Future days return 0L.
     */
    fun week(offsetWeeks: Int = 0): List<Long> {
        if (!hasAccess()) return List(7) { 0L }
        val zone = ZoneId.systemDefault()
        val today = LocalDate.now(zone)
        val targetWeek = today.plusWeeks(offsetWeeks.toLong())
        val monday = targetWeek.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
        val now = System.currentTimeMillis()
        val result = ArrayList<Long>()

        for (i in 0 until 7) {
            val day = monday.plusDays(i.toLong())
            val start = day.atStartOfDay(zone).toInstant().toEpochMilli()
            val end = day.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()

            if (start > now) {
                result.add(0L) // Future day
                continue
            }

            val queryEnd = end.coerceAtMost(now)
            var dayMs = 0L
            try {
                val stats = usm.queryAndAggregateUsageStats(start, queryEnd)
                stats?.forEach { (pkg, usageStats) ->
                    if (pkg !in launchers && pkg != "com.android.systemui" && !pkg.contains("inputmethod")) {
                        dayMs += usageStats.totalTimeInForeground
                    }
                }
            } catch (_: Throwable) {}
            result.add(dayMs)
        }
        return result
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
