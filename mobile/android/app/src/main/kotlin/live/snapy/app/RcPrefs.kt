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
    fun int(k: String) = sp.getInt(k, (DEFAULTS[k] as? Int) ?: 0)
    fun long(k: String) = sp.getLong(k, 0L)
    fun str(k: String) = sp.getString(k, (DEFAULTS[k] as? String) ?: "") ?: ""

    fun putLong(k: String, v: Long) = sp.edit().putLong(k, v).apply()
    fun putString(k: String, v: String) = sp.edit().putString(k, v).apply()
    fun putBool(k: String, v: Boolean) = sp.edit().putBoolean(k, v).apply()

    /** User preferences as JSON (for Flutter). */
    fun prefsJson(): JSONObject {
        val o = JSONObject()
        for ((k, d) in DEFAULTS) when (d) {
            is Boolean -> o.put(k, bool(k))
            is Int -> o.put(k, int(k))
            else -> o.put(k, str(k))
        }
        return o
    }

    /** Merge changes from Flutter; unknown keys are ignored. */
    fun update(changes: JSONObject) {
        val e = sp.edit()
        for (k in changes.keys()) when (DEFAULTS[k]) {
            is Boolean -> e.putBoolean(k, changes.optBoolean(k))
            is Int -> e.putInt(k, changes.optInt(k))
            is String -> e.putString(k, changes.optString(k))
        }
        e.apply()
    }

    companion object {
        val DEFAULTS: Map<String, Any> = linkedMapOf(
            "chip_enabled" to true,
            "chip_style" to "orb",              // "orb" = the accessibility pill (default), "island" = camera-centred chip
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
