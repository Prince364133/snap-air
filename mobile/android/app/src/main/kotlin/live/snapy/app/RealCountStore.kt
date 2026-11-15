package live.snapy.app

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.time.LocalDate

/**
 * Daily Real Count data: reels/shorts watched and short-video time per app.
 * Stored as plain JSON in the app's private folder (…/snapy/realcount/YYYY-MM-DD.json),
 * the same folder the shared Python brain uses, so "how many reels did I watch?" works later.
 * Every instance shares one in-memory day (the accessibility pill and RealCountController
 * both read it), guarded by one lock.
 */
class RealCountStore(ctx: Context) {
    private val dir = File(ctx.filesDir, "snapy/realcount").apply { mkdirs() }

    private fun rollover() {
        val today = LocalDate.now()
        if (day != today || data == null) {
            if (data != null) save()
            day = today
            data = load(today)
        }
    }

    private fun file(d: LocalDate) = File(dir, "$d.json")

    private fun load(d: LocalDate): JSONObject =
        try { JSONObject(file(d).readText()) } catch (_: Exception) { JSONObject().put("date", d.toString()).put("apps", JSONObject()) }

    fun save() {
        synchronized(lock) {
            val d = data ?: return
            try { file(day).writeText(d.toString()) } catch (_: Exception) { }
        }
    }

    private fun app(pkg: String): JSONObject {
        val apps = data!!.getJSONObject("apps")
        if (!apps.has(pkg)) apps.put(pkg, JSONObject().put("reels", 0).put("reel_ms", 0L))
        return apps.getJSONObject(pkg)
    }

    fun addReel(pkg: String) {
        synchronized(lock) {
            rollover()
            val a = app(pkg)
            a.put("reels", a.optInt("reels") + 1)
            dirty++
            if (dirty >= 10) { dirty = 0; save() }      // don't lose a long session if the service is killed
        }
    }

    fun addReelTime(pkg: String, ms: Long) {
        if (ms <= 0) return
        synchronized(lock) {
            rollover()
            val a = app(pkg)
            a.put("reel_ms", a.optLong("reel_ms") + ms)
        }
    }

    fun reels(pkg: String): Int = synchronized(lock) {
        rollover(); data!!.getJSONObject("apps").optJSONObject(pkg)?.optInt("reels") ?: 0
    }

    fun totalReels(): Int = synchronized(lock) {
        rollover()
        val apps = data!!.getJSONObject("apps")
        apps.keys().asSequence().sumOf { apps.getJSONObject(it).optInt("reels") }
    }

    fun today(): JSONObject = synchronized(lock) { rollover(); JSONObject(data.toString()) }

    companion object {
        private val lock = Any()
        private var day: LocalDate = LocalDate.now()
        private var data: JSONObject? = null
        private var dirty = 0
    }
}
