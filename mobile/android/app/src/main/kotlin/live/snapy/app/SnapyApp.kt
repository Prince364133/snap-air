package live.snapy.app

import android.app.Application
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter

/**
 * Why this exists: the accessibility service ("Snapy Metrics Collection") lives in the app's
 * process. When that process crashes, Android unbinds the service and puts it on its
 * "crashed services" list: it is not rebound until the user toggles it again, and ColorOS /
 * Realme UI / HyperOS show it as OFF. So one bug anywhere (an overlay animation, a Flutter
 * channel call) silently switched the Reel counter off.
 *
 * Fix at the root, in two layers:
 *  1. [CrashLog] records every uncaught crash (stack, Android version, phone) to
 *     files/diag/, so it can be shown in the app and fixed instead of guessed.
 *  2. [guardMainLooper]: a RuntimeException thrown by OUR code inside a main-thread callback
 *     (overlay, chip, timers, accessibility events) is recorded and the loop carries on, so it
 *     can't kill the process. Errors (OOM, linkage), and anything during activity/app startup
 *     or with no Snapy frame in the stack, still crash normally, so we never hide a broken
 *     screen.
 */
class SnapyApp : Application() {
    override fun onCreate() {
        super.onCreate()
        CrashLog.install(this)
        AppForeground.install(this)
        guardMainLooper()
    }

    private fun guardMainLooper() {
        Handler(Looper.getMainLooper()).post {
            while (true) {
                try {
                    Looper.loop()
                    return@post                                   // the looper quit: process is ending
                } catch (t: Throwable) {
                    if (!CrashLog.recoverable(t)) throw t
                    CrashLog.record(this, "main-loop (recovered)", t)
                }
            }
        }
    }
}

object CrashLog {
    private const val TAG = "SnapyCrash"
    private const val KEEP = 10

    fun install(ctx: Context) {
        val app = ctx.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, t ->
            try { record(app, "uncaught on ${thread.name}", t) } catch (_: Throwable) { }
            if (previous != null) previous.uncaughtException(thread, t)
            else { android.os.Process.killProcess(android.os.Process.myPid()); System.exit(10) }
        }
    }

    /** True for a bug in our own callback code that is safe to skip. */
    fun recoverable(t: Throwable): Boolean {
        if (t !is RuntimeException) return false                          // OOM, StackOverflow, linkage: crash
        val frames = generateSequence<Throwable>(t) { it.cause }.flatMap { it.stackTrace.asSequence() }.toList()
        // every exception caught by the guard has the guard's own frame (SnapyApp...guardMainLooper)
        // under it: that frame must not count as "our code", or framework/plugin crashes are swallowed too
        if (frames.none { it.className.startsWith("live.snapy.app") && !it.className.startsWith("live.snapy.app.SnapyApp") }) return false
        val startup = setOf("handleBindApplication", "performLaunchActivity", "handleLaunchActivity",
            "handleCreateService", "handleResumeActivity")
        return frames.none { it.className == "android.app.ActivityThread" && it.methodName in startup }
    }

    /** Same fault (place + exception + top frame) -> when it was last written. */
    private val lastWritten = HashMap<String, Long>()
    private const val REPEAT_MS = 60_000L

    /**
     * Never throws. Keeps the newest [KEEP] reports. A fault that repeats (e.g. on every
     * accessibility event) is written at most once a minute, so it can't turn into disk I/O
     * on every event.
     */
    fun record(ctx: Context, where: String, t: Throwable) {
        try {
            val sig = "$where|${t.javaClass.name}|${t.stackTrace.firstOrNull()}"
            val now = android.os.SystemClock.elapsedRealtime()
            synchronized(lastWritten) {
                val prev = lastWritten[sig]
                if (prev != null && now - prev < REPEAT_MS) return
                lastWritten[sig] = now
                if (lastWritten.size > 64) lastWritten.clear()
            }
            Log.e(TAG, where, t)
            val dir = File(ctx.filesDir, "diag").apply { mkdirs() }
            val sw = StringWriter()
            t.printStackTrace(PrintWriter(sw))
            val text = buildString {
                append("time=").append(System.currentTimeMillis()).append('\n')
                append("where=").append(where).append('\n')
                append("android=").append(Build.VERSION.SDK_INT).append(" (").append(Build.VERSION.RELEASE).append(")\n")
                append("device=").append(Build.MANUFACTURER).append(' ').append(Build.MODEL).append('\n')
                append(sw.toString().take(16_000))
            }
            File(dir, "crash-${System.currentTimeMillis()}.txt").writeText(text)
            dir.listFiles { f -> f.name.startsWith("crash-") }?.sortedByDescending { it.name }
                ?.drop(KEEP)?.forEach { it.delete() }
        } catch (_: Throwable) { }
    }

    /** Newest first: [{file, text}] for the app's Diagnostics screen. */
    fun reports(ctx: Context): List<Pair<String, String>> = try {
        File(ctx.filesDir, "diag").listFiles { f -> f.name.startsWith("crash-") }
            ?.sortedByDescending { it.name }?.map { it.name to it.readText() } ?: emptyList()
    } catch (_: Throwable) { emptyList() }

    fun clear(ctx: Context) {
        try { File(ctx.filesDir, "diag").listFiles { f -> f.name.startsWith("crash-") }?.forEach { it.delete() } } catch (_: Throwable) { }
    }
}

/**
 * Is the Reel counter really running? Separates the cases the user can't tell apart:
 *  - "off": not enabled in Settings (never turned on, or the Restricted-settings block on
 *    sideloaded apps, Android 13+, switched it straight back off)
 *  - "stopped": enabled in Settings but not connected: the phone killed Snapy (OEM battery
 *    manager), or it crashed (see [CrashLog])
 *  - "on": connected and receiving events
 */
object A11yHealth {
    const val PREF_CONNECTED_AT = "a11y_connected_at"
    const val PREF_DISCONNECTED_AT = "a11y_disconnected_at"

    fun enabledInSettings(ctx: Context): Boolean {
        val list = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        val me = "${ctx.packageName}/${SnapyAccessibilityService::class.java.name}"
        val meShort = "${ctx.packageName}/.${SnapyAccessibilityService::class.java.simpleName}"
        return list.split(':').any { it.equals(me, true) || it.equals(meShort, true) }
    }

    fun state(ctx: Context): Map<String, Any> {
        val enabled = enabledInSettings(ctx)
        val connected = SnapyAccessibilityService.instance != null
        val prefs = RcPrefs(ctx)
        val crashes = CrashLog.reports(ctx)
        return mapOf(
            "state" to when { connected -> "on"; enabled -> "stopped"; else -> "off" },
            "enabled" to enabled,
            "connected" to connected,
            "connected_at" to prefs.long(PREF_CONNECTED_AT),
            "disconnected_at" to prefs.long(PREF_DISCONNECTED_AT),
            "last_crash" to (crashes.firstOrNull()?.second ?: ""),
            "crash_count" to crashes.size,
            "manufacturer" to Build.MANUFACTURER,
        )
    }
}
