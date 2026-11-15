package live.snapy.app

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/**
 * The same strings as the Flutter screens: assets/i18n/<lang>.json, read from the APK
 * (flutter_assets/…). Nested keys are flattened to dotted keys; missing keys fall back to
 * English, then to the key. Language = RcPrefs "ui_lang" ('auto' = the phone's language).
 */
object Strings {
    private val supported = setOf("en", "hi", "ta", "te", "mr", "bn")
    @Volatile private var lang = ""
    @Volatile private var mine: Map<String, String> = emptyMap()
    @Volatile private var en: Map<String, String> = emptyMap()

    fun t(ctx: Context, key: String, params: Map<String, String> = emptyMap()): String {
        ensure(ctx)
        var v = mine[key] ?: en[key] ?: key
        for ((k, p) in params) v = v.replace("{$k}", p)
        return v
    }

    /** The language in use (for text-to-speech). */
    fun lang(ctx: Context): String { ensure(ctx); return lang }

    /** Call after the language setting changes. */
    fun reload() { lang = "" }

    @Synchronized
    private fun ensure(ctx: Context) {
        val pref = RcPrefs(ctx).str("ui_lang")
        val device = Locale.getDefault().language
        val want = if (pref != "auto" && pref in supported) pref else if (device in supported) device else "en"
        if (want == lang) return
        en = read(ctx, "en")
        mine = if (want == "en") en else read(ctx, want)
        lang = want
    }

    private fun read(ctx: Context, l: String): Map<String, String> = try {
        val text = ctx.assets.open("flutter_assets/assets/i18n/$l.json").bufferedReader().use { it.readText() }
        HashMap<String, String>().also { flatten(JSONObject(text), "", it) }
    } catch (_: Exception) { emptyMap() }

    private fun flatten(o: JSONObject, prefix: String, out: MutableMap<String, String>) {
        for (k in o.keys()) {
            if (k.startsWith("_")) continue
            val key = if (prefix.isEmpty()) k else "$prefix.$k"
            when (val v = o.opt(k)) {
                is JSONObject -> flatten(v, key, out)
                is JSONArray -> out[key] = (0 until v.length()).joinToString("\n") { v.optString(it) }
                null, JSONObject.NULL -> {}
                else -> out[key] = v.toString()
            }
        }
    }
}
