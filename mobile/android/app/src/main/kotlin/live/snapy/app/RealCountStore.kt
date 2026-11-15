package live.snapy.app

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.time.LocalDate

/**
 * Daily Real Count data: reels/shorts watched and short-video time per app.
 * Stored as plain JSON in the app's private folder (…/snapy/realcount/YYYY-MM-DD.json),
 * the same folder the shared Python brain uses, so "how many reels did I watch?" works later.
 */
class RealCountStore(ctx: Context) {
    private val dir = File(ctx.filesDir, "snapy/realcount").apply { mkdirs() }
    private var day: LocalDate = LocalDate.now()
    private var data: JSONObject = load(day)

    @Synchronized
    private fun rollover() {
        val today = LocalDate.now()
        if (today != day) {
            save()
            day = today
            data = load(day)
        }
    }

    private fun file(d: LocalDate) = File(dir, "$d.json")

    private fun load(d: LocalDate): JSONObject =
        try { JSONObject(file(d).readText()) } catch (_: Exception) { JSONObject().put("date", d.toString()).put("apps", JSONObject()) }

    @Synchronized
    fun save() {
        try { file(day).writeText(data.toString()) } catch (_: Exception) { }
    }

    private fun app(pkg: String): JSONObject {
        val apps = data.getJSONObject("apps")
        if (!apps.has(pkg)) apps.put(pkg, JSONObject().put("reels", 0).put("reel_ms", 0L))
        return apps.getJSONObject(pkg)
    }

    @Synchronized
    fun addReel(pkg: String) {
        rollover()
        val a = app(pkg)
        a.put("reels", a.optInt("reels") + 1)
    }

    @Synchronized
    fun addReelTime(pkg: String, ms: Long) {
        if (ms <= 0) return
        rollover()
        val a = app(pkg)
        a.put("reel_ms", a.optLong("reel_ms") + ms)
    }

    @Synchronized
    fun reels(pkg: String): Int { rollover(); return data.getJSONObject("apps").optJSONObject(pkg)?.optInt("reels") ?: 0 }

    @Synchronized
    fun totalReels(): Int {
        rollover()
        val apps = data.getJSONObject("apps")
        return apps.keys().asSequence().sumOf { apps.getJSONObject(it).optInt("reels") }
    }

    @Synchronized
    fun today(): JSONObject { rollover(); return JSONObject(data.toString()) }
}
