package live.snapy.app

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.view.KeyEvent
import org.json.JSONArray
import org.json.JSONObject

/**
 * Executes the phone actions the shared brain decided on, with Android APIs.
 * Each op is a fixed, deterministic script (Google Play accessibility policy: the AI
 * chooses *which* action; it never improvises taps).
 * Key combos map to phone actions through app.json ("android.key_actions").
 */
class OpExecutor(private val ctx: Context) {
    private val audio = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val keyActions: JSONObject by lazy {
        JSONObject(CoreBridge.get(ctx).configNow("android.key_actions").takeIf { it != "null" } ?: "{}")
    }

    /** Runs one op event; returns false if this op isn't available on the phone. */
    fun runOp(op: JSONObject): Boolean {
        val args = op.optJSONArray("args")
        val kwargs = op.optJSONObject("kwargs") ?: JSONObject()
        return try {
            when (op.getString("op")) {
                "open_url" -> openUrl(args!!.getString(0), kwargs.optString("package", ""))
                "launch_app" -> launch(args!!.getString(0))
                "media" -> media(args!!.getString(0), if (args.length() > 1) args.getInt(1) else 1)
                "hotkey", "press" -> phoneAction(args)
                else -> false
            }
        } catch (e: Exception) {
            false
        }
    }

    private fun start(i: Intent) = ctx.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))

    private fun openUrl(url: String, pkg: String): Boolean {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        if (pkg.isNotEmpty()) {
            // prefer the installed app (WhatsApp, Instagram, YouTube…); fall back to the browser
            val launch = ctx.packageManager.getLaunchIntentForPackage(pkg)
            if (launch != null) {
                try { start(Intent(intent).setPackage(pkg)); return true } catch (_: ActivityNotFoundException) { start(launch); return true }
            }
        }
        start(intent)
        return true
    }

    private fun launch(pkg: String): Boolean {
        val i = ctx.packageManager.getLaunchIntentForPackage(pkg) ?: return false
        start(i)
        return true
    }

    private fun media(key: String, times: Int): Boolean {
        when (key) {
            "volumeup", "volumedown" -> repeat(times.coerceIn(1, 15)) {
                audio.adjustStreamVolume(AudioManager.STREAM_MUSIC,
                    if (key == "volumeup") AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER, AudioManager.FLAG_SHOW_UI)
            }
            "volumemute" -> audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_TOGGLE_MUTE, AudioManager.FLAG_SHOW_UI)
            "playpause" -> mediaKey(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
            "nexttrack" -> mediaKey(KeyEvent.KEYCODE_MEDIA_NEXT)
            "prevtrack" -> mediaKey(KeyEvent.KEYCODE_MEDIA_PREVIOUS)
            else -> return false
        }
        return true
    }

    private fun mediaKey(code: Int) {
        audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
        audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
    }

    /** Desktop key combos -> phone actions (back, home, recents…) via the Real Count service. */
    private fun phoneAction(args: JSONArray?): Boolean {
        if (args == null) return false
        val combo = (0 until args.length()).joinToString("+") { args.get(it).toString().lowercase() }
        val action = keyActions.optString(combo, "")
        if (action.isEmpty()) return false
        if (SnapyAccessibilityService.global(action)) return true
        return when (action) {
            "home" -> { start(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)); true }
            else -> false
        }
    }
}
