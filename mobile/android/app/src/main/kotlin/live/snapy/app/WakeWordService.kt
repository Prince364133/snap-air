package live.snapy.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.RecognitionListener
import org.vosk.android.SpeechService
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipInputStream

/**
 * "Hey Snapy" (opt-in). A foreground microphone service running a small offline Vosk model
 * restricted to the assistant's name, so a renamed assistant works with no retraining.
 * Nothing is recorded or sent anywhere: audio is checked for the name and discarded.
 * When the name is heard, VoiceController takes the microphone for one spoken turn.
 */
class WakeWordService : Service(), RecognitionListener {
    private var speech: SpeechService? = null
    private var model: Model? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            startInForeground()
            when (intent?.action) {
                ACTION_PAUSE -> { speech?.stop(); speech = null }
                else -> Thread {
                    try {
                        startListening()
                    } catch (t: Throwable) {
                        android.util.Log.e("WakeWordService", "Error in startListening", t)
                    }
                }.start()
            }
        } catch (t: Throwable) {
            android.util.Log.e("WakeWordService", "Error in onStartCommand", t)
            stopSelf()
        }
        return START_STICKY
    }

    private fun startInForeground() {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL) == null) {
                nm.createNotificationChannel(NotificationChannel(CHANNEL, "Listening for “Hey Snapy”", NotificationManager.IMPORTANCE_MIN))
            }
            val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
            val n: Notification = NotificationCompat.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.ic_btn_speak_now)
                .setContentTitle("Snapy is listening for its name")
                .setContentText("Audio stays on your phone. Turn off in Snapy → Settings.")
                .setOngoing(true)
                .setContentIntent(open)
                .build()
            if (Build.VERSION.SDK_INT >= 30) startForeground(7, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            else startForeground(7, n)
        } catch (e: Exception) {
            android.util.Log.e("WakeWordService", "startForeground failed", e)
            try {
                if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
                else @Suppress("DEPRECATION") stopForeground(true)
            } catch (_: Throwable) {}
            stopSelf()
        }
    }

    @Synchronized
    private fun startListening() {
        if (speech != null || VoiceController.active) return
        val core = CoreBridge.get(this)
        val cfg = JSONObject(core.configNowCall("voice_config"))
        val m = model ?: loadModel(cfg.optJSONObject("wake_model") ?: return)?.also { model = it } ?: return
        // grammar mode: only the wake phrases (+ "[unk]") can be recognised -> cheap and few false wakes
        val grammar = JSONArray(cfg.optJSONArray("wake_phrases")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: listOf("hey snappy"))
            .put("[unk]")
        val rec = Recognizer(m, 16000f, grammar.toString())
        speech = SpeechService(rec, 16000f).also { it.startListening(this) }
    }

    /** Downloads the 36 MB model once (progress goes to the app as a "setup" event). */
    private fun loadModel(spec: JSONObject): Model? {
        val dir = File(filesDir, "snapy/models/" + spec.getString("folder"))
        if (!File(dir, "am").exists() && !File(dir, "conf").exists()) {
            val core = CoreBridge.get(this)
            try {
                val conn = URL(spec.getString("url")).openConnection() as HttpURLConnection
                val total = conn.contentLengthLong
                var done = 0L
                ZipInputStream(object : java.io.FilterInputStream(conn.inputStream) {
                    override fun read(b: ByteArray, off: Int, len: Int): Int {
                        val n = super.read(b, off, len)
                        if (n > 0) { done += n; if (done % (512 * 1024) < n) progress(core, done, total) }
                        return n
                    }
                }).use { zip ->
                    var e = zip.nextEntry
                    while (e != null) {
                        val out = File(dir.parentFile, e.name)
                        if (!out.canonicalPath.startsWith(dir.parentFile!!.canonicalPath)) throw SecurityException("bad zip entry")
                        if (e.isDirectory) out.mkdirs() else { out.parentFile?.mkdirs(); out.outputStream().use { zip.copyTo(it) } }
                        e = zip.nextEntry
                    }
                }
                progress(core, total, total)
            } catch (ex: Exception) {
                core.publish(JSONObject().put("type", "toast").put("text", "Couldn't download the wake-word model: ${ex.message}"))
                return null
            }
        }
        return try { Model(dir.absolutePath) } catch (_: Exception) { null }
    }

    private fun progress(core: CoreBridge, done: Long, total: Long) = core.publish(JSONObject().put("type", "setup")
        .put("items", JSONArray().put(JSONObject().put("id", "wake").put("label", "“Hey Snapy” model")
            .put("done", done).put("total", total).put("state", if (done >= total && total > 0) "done" else "downloading"))))

    // ---- Vosk callbacks
    override fun onPartialResult(hypothesis: String?) = check(hypothesis, "partial")
    override fun onResult(hypothesis: String?) = check(hypothesis, "text")
    override fun onFinalResult(hypothesis: String?) = check(hypothesis, "text")
    override fun onError(e: Exception?) { speech = null }
    override fun onTimeout() { speech = null }

    private fun check(json: String?, key: String) {
        val heard = try { JSONObject(json ?: "{}").optString(key) } catch (_: Exception) { "" }
        if (heard.isBlank() || heard == "[unk]" || heard.contains("[unk]")) return
        speech?.stop(); speech = null
        VoiceController.start(this, "voice")             // "Hey Snapy" -> one spoken turn
    }

    override fun onDestroy() {
        speech?.shutdown(); speech = null
        model?.close(); model = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "snapy_wake"
        private const val ACTION_PAUSE = "pause"
        @Volatile var enabled = false

        fun enable(ctx: Context, on: Boolean) {
            enabled = on
            val i = Intent(ctx, WakeWordService::class.java)
            if (on) {
                if (androidx.core.content.ContextCompat.checkSelfPermission(ctx, android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    enabled = false
                    return
                }
                try {
                    ctx.startForegroundService(i)
                } catch (e: Exception) {
                    android.util.Log.e("WakeWordService", "Failed to startForegroundService", e)
                    enabled = false
                }
            } else {
                try { ctx.stopService(i) } catch (_: Exception) {}
            }
        }

        fun pause(ctx: Context) { if (enabled) ctx.startService(Intent(ctx, WakeWordService::class.java).setAction(ACTION_PAUSE)) }
        fun resume(ctx: Context) { if (enabled) ctx.startService(Intent(ctx, WakeWordService::class.java)) }
    }
}
