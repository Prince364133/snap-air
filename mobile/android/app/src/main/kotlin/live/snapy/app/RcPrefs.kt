package live.snapy.app

import android.content.Context
import org.json.JSONObject

/**
 * Real Count preferences and live state, shared by the chip, the counter, the boot receiver
 * and Flutter (channel "rcPrefs"/"setRcPrefs"/"rcState"). Same keys and defaults as
 * RcPrefs.defaults in lib/realcount/realcount_data.dart.
 */
class RcPrefs(ctx: Context) {
    private val sp = ctx.applicationContext.getSharedPreferences("snapy_rc", Context.MODE_PRIVATE)

    fun bool(k: String) = sp.getBoolean(k, (DEFAULTS[k] as? Boolean) ?: false)
    fun bool(k: String, def: Boolean) = sp.getBoolean(k, def)
    fun int(k: String) = sp.getInt(k, (DEFAULTS[k] as? Int) ?: 0)
    fun int(k: String, def: Int) = sp.getInt(k, def)
    fun long(k: String) = sp.getLong(k, 0L)
    fun long(k: String, def: Long) = sp.getLong(k, def)
    fun str(k: String) = sp.getString(k, (DEFAULTS[k] as? String) ?: "") ?: ""
    fun str(k: String, def: String) = sp.getString(k, def) ?: def

    fun putLong(k: String, v: Long) = sp.edit().putLong(k, v).apply()
    fun putInt(k: String, v: Int) = sp.edit().putInt(k, v).apply()
    fun putString(k: String, v: String) = sp.edit().putString(k, v).apply()
    fun putBool(k: String, v: Boolean) = sp.edit().putBoolean(k, v).apply()
    fun remove(k: String) = sp.edit().remove(k).apply()

    /** User preferences as JSON (for Flutter). */
    fun prefsJson(): JSONObject {
        val o = JSONObject()
        for ((k, d) in DEFAULTS) when (d) {
            is Boolean -> o.put(k, bool(k))
            is Int -> o.put(k, int(k))
            else -> o.put(k, str(k))
        }
        // Include dynamic keys
        for ((k, v) in sp.all) {
            if (!o.has(k)) {
                o.put(k, v)
            }
        }
        return o
    }

    /** Merge changes from Flutter; unknown keys are persisted dynamically. */
    fun update(changes: JSONObject) {
        val e = sp.edit()
        for (k in changes.keys()) {
            val d = DEFAULTS[k]
            if (d != null) {
                when (d) {
                    is Boolean -> e.putBoolean(k, changes.optBoolean(k))
                    is Int -> e.putInt(k, changes.optInt(k))
                    is String -> e.putString(k, changes.optString(k))
                }
            } else {
                val v = changes.opt(k)
                when (v) {
                    is Boolean -> e.putBoolean(k, v)
                    is Int -> e.putInt(k, v)
                    is Long -> e.putLong(k, v)
                    is String -> e.putString(k, v)
                }
            }
        }
        e.apply()
    }

    companion object {
        val DEFAULTS: Map<String, Any> = linkedMapOf(
            "chip_enabled" to true,
            "chip_style" to "island",           // camera punch-hole halo & dropped capsule strip
            "chip_size" to "normal",
            "chip_x" to -1,
            "chip_y" to -1,
            "hidden_day" to "",
            "creator_mode" to false,
            "intention_prompt" to true,
            "nudges" to true,
            "speak_nudges" to false,
            "reel_limit" to 0,
            "bedtime" to "",
            "simple_mode" to false,
            "ui_lang" to "auto",
            "overlay_fallback" to true,
            "counter_reports" to false,
        )

        // live state keys (not user preferences)
        const val FOCUS_UNTIL = "s_focus_until"
        const val PAUSED_UNTIL = "s_paused_until"
        const val HIDDEN_UNTIL = "s_hidden_until"
        const val INTENT_ID = "s_intent_id"
        const val INTENT_ENDS = "s_intent_ends"
        const val INTENT_MIN = "s_intent_min"
        const val NUDGE_STATE = "s_nudge_state"
        const val WAKE_WANTED = "s_wake_wanted"
    }
}
