package live.snapy.app

import android.Manifest
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.AlarmClock
import android.provider.Settings
import android.view.KeyEvent
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
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
                // ---- Phase 4: phone actions (each a fixed script; sends/calls were confirmed by the user)
                "whatsapp_send" -> whatsapp(kwargs.getString("number"), kwargs.getString("text"))
                "sms" -> { start(Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:" + kwargs.getString("number"))).putExtra("sms_body", kwargs.getString("text"))); true }
                "call" -> call(kwargs.getString("number"))
                "alarm" -> { start(Intent(AlarmClock.ACTION_SET_ALARM).putExtra(AlarmClock.EXTRA_HOUR, kwargs.getInt("hour"))
                    .putExtra(AlarmClock.EXTRA_MINUTES, kwargs.getInt("minute")).putExtra(AlarmClock.EXTRA_MESSAGE, kwargs.optString("label", "Snapy"))
                    .putExtra(AlarmClock.EXTRA_SKIP_UI, true)); true }
                "timer" -> { start(Intent(AlarmClock.ACTION_SET_TIMER).putExtra(AlarmClock.EXTRA_LENGTH, kwargs.getInt("seconds"))
                    .putExtra(AlarmClock.EXTRA_MESSAGE, "Snapy").putExtra(AlarmClock.EXTRA_SKIP_UI, true)); true }
                "navigate" -> { start(Intent(Intent.ACTION_VIEW, Uri.parse("google.navigation:q=" + Uri.encode(kwargs.getString("place"))))); true }
                "torch" -> torch(kwargs.getBoolean("on"))
                "panel" -> panel(kwargs.getString("panel"))
                "type_text" -> later { SnapyAccessibilityService.instance?.typeIntoFocused(kwargs.getString("text")) ?: false }
                "screen_tap" -> later { tapOnScreen(kwargs.getString("query")); true }
                // ---- from the paired laptop (lib/core_runtime/sync_runner.dart)
                "copy_text" -> copyText(kwargs.getString("text"), kwargs.optBoolean("notify", false))
                "notify" -> notify(kwargs.optString("title", "Snapy"), kwargs.optString("text", ""))
                "focus" -> focus(kwargs.optInt("minutes", 25), kwargs.optBoolean("dnd", false))
                else -> false
            }
        } catch (e: Exception) {
            false
        }
    }

    private fun start(i: Intent) = ctx.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))

    /** Text sent from the laptop: on the clipboard, plus a notification (Android 10+ hides clipboard reads). */
    private fun copyText(text: String, notify: Boolean): Boolean {
        (ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("Snapy", text))
        if (notify) notify("Copied from your laptop", text.take(200))
        else Toast.makeText(ctx, "Copied", Toast.LENGTH_SHORT).show()
        return true
    }

    private fun notify(title: String, text: String): Boolean {
        Reminders.ensureChannel(ctx)
        val open = PendingIntent.getActivity(ctx, 1, Intent(ctx, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = NotificationCompat.Builder(ctx, Reminders.CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        return try { NotificationManagerCompat.from(ctx).notify((title + text).hashCode(), n); true } catch (_: SecurityException) { false }
    }

    /** Focus from the laptop: Real Count focus, plus Do Not Disturb when the user granted that access. */
    private fun focus(minutes: Int, dnd: Boolean): Boolean {
        val min = minutes.coerceIn(1, 480)
        val c = RealCountController.active
        if (c != null) c.startFocus(min) else RcPrefs(ctx).putLong(RcPrefs.FOCUS_UNTIL, System.currentTimeMillis() + min * 60000L)
        if (dnd) {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.isNotificationPolicyAccessGranted && nm.currentInterruptionFilter == NotificationManager.INTERRUPTION_FILTER_ALL) {
                nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_PRIORITY)
                // back to normal when the focus ends (best effort: not restored if the process is killed)
                main.postDelayed({
                    if (nm.currentInterruptionFilter == NotificationManager.INTERRUPTION_FILTER_PRIORITY) {
                        nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_ALL)
                    }
                }, min * 60000L)
            }
        }
        return true
    }

    private val main = Handler(Looper.getMainLooper())

    /** Screen actions wait for the Snapy sheet to close so they act on the app underneath. */
    private fun later(block: () -> Boolean): Boolean { main.postDelayed({ block() }, 700); return true }

    /** WhatsApp: open the chat with the message filled in, then tap Send (fixed script, after the user said yes). */
    private fun whatsapp(number: String, text: String): Boolean {
        val digits = number.filter { it.isDigit() }.let { if (it.length == 10) "91$it" else it }   // local numbers -> +91
        val uri = Uri.parse("https://wa.me/$digits?text=" + Uri.encode(text))
        val pkg = listOf("com.whatsapp", "com.whatsapp.w4b").firstOrNull { ctx.packageManager.getLaunchIntentForPackage(it) != null }
        start(Intent(Intent.ACTION_VIEW, uri).apply { if (pkg != null) setPackage(pkg) })
        val selectors = CoreBridge.get(ctx).configNow("android.selectors")
        SnapyAccessibilityService.instance?.tapWhenVisible(JSONObject(selectors).optJSONArray("whatsapp_send") ?: JSONArray(), 8000)
        return true
    }

    private fun call(number: String): Boolean {
        val direct = ctx.checkSelfPermission(Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED
        start(Intent(if (direct) Intent.ACTION_CALL else Intent.ACTION_DIAL, Uri.parse("tel:" + Uri.encode(number))))
        return true
    }

    private fun torch(on: Boolean): Boolean {
        val cm = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val id = cm.cameraIdList.firstOrNull { cm.getCameraCharacteristics(it).get(android.hardware.camera2.CameraCharacteristics.FLASH_INFO_AVAILABLE) == true } ?: return false
        cm.setTorchMode(id, on)
        return true
    }

    /** Android lets the user (not apps) switch Wi-Fi/Bluetooth: open the quick panel for them. */
    private fun panel(name: String): Boolean {
        val action = when (name) {
            "wifi" -> Settings.Panel.ACTION_WIFI
            "internet" -> Settings.Panel.ACTION_INTERNET_CONNECTIVITY
            "nfc" -> Settings.Panel.ACTION_NFC
            "volume" -> Settings.Panel.ACTION_VOLUME
            "bluetooth" -> Settings.ACTION_BLUETOOTH_SETTINGS
            else -> Settings.Panel.ACTION_INTERNET_CONNECTIVITY
        }
        start(Intent(action))
        return true
    }

    /** "tap the second video": screen nodes -> shared matcher (same as Windows) -> click. */
    private fun tapOnScreen(query: String) {
        val svc = SnapyAccessibilityService.instance ?: return
        val nodes = svc.snapshotNodes()
        CoreBridge.get(ctx).findOnScreen(query, nodes.toString()) { i ->
            if (i < 0 || !svc.clickNode(i)) {
                CoreBridge.get(ctx).publish(JSONObject().put("type", "toast").put("text", "I couldn't find “$query” on this screen."))
            }
        }
    }

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
