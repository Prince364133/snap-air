package live.snapy.app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
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
 * Snapy's ONE long-lived microphone foreground service (type microphone), in two modes:
 *  - wake word (opt-in): a small offline Vosk model restricted to the assistant's name, so a
 *    renamed assistant works with no retraining. Audio is checked for the name and discarded.
 *    When the name is heard, [Activation] runs one spoken turn.
 *  - recording (docs/ANDROID_NEXT_PLAN.md §5, meeting notes with the app closed): the same
 *    service records the meeting (MeetingAudioRecorder: AAC .m4a in files/snapy/meetings/ +
 *    offline live transcript), notification "Recording meeting notes", red capsule under the
 *    camera. It keeps running with Snapy closed or the phone locked.
 * Android rules: a microphone FGS may only be STARTED while Snapy is visible (Android 11+
 * while-in-use, Android 14+ FGS type checks), so recording is started from the foreground UI
 * call or while the wake-word service already runs; after a reboot on Android 14+ the user taps
 * the BootReceiver notification. Never started from the background.
 */
class WakeWordService : Service(), RecognitionListener {
    private var speech: SpeechService? = null
    private var model: Model? = null
    private var recorder: MeetingAudioRecorder? = null
    private var recId = ""
    private var recPath = ""
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var wakePhrases = listOf<String>()
    private val recTick = object : Runnable {
        override fun run() {
            val r = recorder ?: return
            val s = (System.currentTimeMillis() - r.startedAt) / 1000
            CameraCapsule.status.show(this@WakeWordService,
                t("meeting.capsule", "● Recording notes") + " " + String.format(java.util.Locale.US, "%02d:%02d", s / 60, s % 60),
                CameraCapsule.RECORDING)
            main.postDelayed(this, 1000)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            when (intent?.action) {
                ACTION_RECORD -> startRecording(intent.getStringExtra("id") ?: "", intent.getStringExtra("path") ?: "")
                ACTION_RECORD_STOP -> stopRecording()
                // the notification's "Stop & save": the runtime ends the meeting, summarises and
                // sends op meeting_audio off (-> ACTION_RECORD_STOP)
                ACTION_STOP_FROM_NOTIF -> CoreBridge.get(this).call("meeting_stop") { }
                ACTION_COMMAND -> commandPending = true
                ACTION_PAUSE -> { startInForeground(); if (recorder == null) { speech?.stop(); speech = null } }
                else -> {
                    if (recorder != null) { startInForeground(); return START_STICKY }          // recording owns the mic
                    if (!enabled) { stopSelfSafely(); return START_NOT_STICKY }                  // sticky restart with wake off
                    startInForeground()
                    Thread { try { startListening() } catch (t: Throwable) { android.util.Log.e(TAG, "startListening failed") } }.start()
                }
            }
        } catch (t: Throwable) {
            android.util.Log.e(TAG, "onStartCommand failed")
            stopSelfSafely()
        }
        return START_STICKY
    }

    private fun channel(id: String, nameKey: String, fallback: String, importance: Int) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(id) == null) {
            val name = Strings.t(this, nameKey).let { if (it == nameKey) fallback else it }
            nm.createNotificationChannel(NotificationChannel(id, name, importance))
        }
    }

    private fun t(key: String, fallback: String) = Strings.t(this, key).let { if (it == key) fallback else it }

    private fun startInForeground() {
        try {
            val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
            val n: Notification = if (recorder != null) {
                channel(REC_CHANNEL, "notif.meeting_channel", "Meeting notes", NotificationManager.IMPORTANCE_LOW)
                val stop = PendingIntent.getService(this, 1, Intent(this, WakeWordService::class.java).setAction(ACTION_STOP_FROM_NOTIF),
                    PendingIntent.FLAG_IMMUTABLE)
                NotificationCompat.Builder(this, REC_CHANNEL)
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle(t("notif.meeting_title", "Recording meeting notes"))
                    .setContentText(t("notif.meeting_text", "Audio stays on your phone. Say “meeting is over, save the notes”."))
                    .setUsesChronometer(true)
                    .setWhen(recorder?.startedAt ?: System.currentTimeMillis())
                    .setOngoing(true)
                    .setContentIntent(open)
                    .addAction(0, t("notif.meeting_stop", "Stop & save"), stop)
                    .build()
            } else {
                channel(CHANNEL, "notif.wake_channel", "Listening for “Hey Snapy”", NotificationManager.IMPORTANCE_MIN)
                NotificationCompat.Builder(this, CHANNEL)
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle(t("notif.wake_listening_title", "Snapy is listening for its name"))
                    .setContentText(t("notif.wake_listening_text", "Audio stays on your phone. Turn off in Snapy → Settings."))
                    .setOngoing(true)
                    .setContentIntent(open)
                    .build()
            }
            if (Build.VERSION.SDK_INT >= 30) startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            else startForeground(NOTIF_ID, n)
            running = true
        } catch (e: Exception) {
            // e.g. ForegroundServiceStartNotAllowedException / SecurityException when not visible
            android.util.Log.e(TAG, "startForeground failed: ${e.javaClass.simpleName}")
            stopSelfSafely()
            throw e
        }
    }

    private fun stopSelfSafely() {
        running = false
        try { stopForeground(STOP_FOREGROUND_REMOVE) } catch (_: Throwable) { }
        stopSelf()
    }

    // ------------------------------------------------------------------ recording mode
    private fun startRecording(id: String, path: String) {
        val core = CoreBridge.get(this)
        if (recorder != null || id.isEmpty() || path.isEmpty()) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            core.call("meeting_audio_saved", id, "", "0") { }
            core.publish(JSONObject().put("type", "toast").put("text", t("meeting.need_mic", "Snapy needs the microphone to record the meeting.")))
            if (!enabled) stopSelfSafely()
            return
        }
        speech?.stop(); speech = null                                            // one microphone user
        recId = id; recPath = path
        val r = MeetingAudioRecorder(path, model = { recognitionModel() }, onText = ::onMeetingText, onLevel = { l ->
            Captions.onVoice(this, "level", "", l)
        })
        recorder = r
        isRecording = true
        try { startInForeground() } catch (_: Exception) {
            recorder = null; isRecording = false
            core.call("meeting_audio_saved", id, "", "0") { }
            core.publish(JSONObject().put("type", "toast").put("text", t("meeting.open_app", "Open Snapy to start recording — Android only allows it while Snapy is on screen.")))
            return
        }
        r.start()
        main.post(recTick)
        Thread { wakePhrases = phrases(JSONObject(core.configNowCall("voice_config"))) }.start()
    }

    private fun stopRecording() {
        val r = recorder ?: return
        recorder = null
        isRecording = false
        main.removeCallbacks(recTick)
        CameraCapsule.status.dismiss()
        val id = recId; val path = recPath
        Thread {
            val f = r.stop()
            CoreBridge.get(this).call("meeting_audio_saved", id, f?.absolutePath ?: "", "${f?.length() ?: 0}") { }
            main.post {
                if (enabled) { try { startInForeground() } catch (_: Exception) { return@post }; Thread { startListening() }.start() }
                else stopSelfSafely()
            }
        }.start()
    }

    /** Recognized speech while recording: transcript lines; "Hey Snapy, …" (or the next phrase
     *  after an activation) is a command, e.g. "meeting is over, save the notes". */
    private fun onMeetingText(text: String, final: Boolean) {
        Captions.onVoice(this, "partial", text)
        if (!final) return
        val core = CoreBridge.get(this)
        val low = text.lowercase()
        val wake = wakePhrases.firstOrNull { low.startsWith(it) }
        if (wake != null || commandPending) {
            commandPending = false
            val cmd = if (wake != null) text.substring(wake.length).trim() else text
            if (cmd.isNotEmpty()) core.call("meeting_command", cmd) { }
            return
        }
        core.call("add_meeting_text", text) { }
    }

    private fun phrases(cfg: JSONObject): List<String> =
        cfg.optJSONArray("wake_phrases")?.let { a -> (0 until a.length()).map { a.getString(it).lowercase() } }?.sortedByDescending { it.length } ?: emptyList()

    /** The Vosk model for free-form recognition (the wake model, if it is on the phone). */
    private fun recognitionModel(): Model? {
        model?.let { return it }
        return try {
            val cfg = JSONObject(CoreBridge.get(this).configNowCall("voice_config"))
            val spec = cfg.optJSONObject("wake_model") ?: return null
            val dir = File(filesDir, "snapy/models/" + spec.getString("folder"))
            if (!File(dir, "am").exists() && !File(dir, "conf").exists()) null else Model(dir.absolutePath).also { model = it }
        } catch (_: Throwable) { null }
    }

    // ------------------------------------------------------------------ wake-word mode
    @Synchronized
    private fun startListening() {
        if (speech != null || VoiceController.active || recorder != null) return
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

    // ---- Vosk callbacks (wake mode)
    override fun onPartialResult(hypothesis: String?) = check(hypothesis, "partial")
    override fun onResult(hypothesis: String?) = check(hypothesis, "text")
    override fun onFinalResult(hypothesis: String?) = check(hypothesis, "text")
    override fun onError(e: Exception?) { speech = null }
    override fun onTimeout() { speech = null }

    private fun check(json: String?, key: String) {
        val heard = try { JSONObject(json ?: "{}").optString(key) } catch (_: Exception) { "" }
        if (heard.isBlank() || heard == "[unk]" || heard.contains("[unk]")) return
        speech?.stop(); speech = null
        Activation.trigger(this, "wake")                  // "Hey Snapy" -> greeting + one spoken turn
    }

    override fun onDestroy() {
        recorder?.let { r -> recorder = null; isRecording = false; Thread { val f = r.stop()
            CoreBridge.get(applicationContext).call("meeting_audio_saved", recId, f?.absolutePath ?: "", "${f?.length() ?: 0}") { } }.start() }
        main.removeCallbacksAndMessages(null)
        CameraCapsule.status.dismiss()
        speech?.shutdown(); speech = null
        model?.close(); model = null
        running = false
        super.onDestroy()
    }

    companion object {
        private const val TAG = "WakeWordService"
        private const val CHANNEL = "snapy_wake"
        private const val REC_CHANNEL = "snapy_meeting"
        private const val NOTIF_ID = 7
        private const val ACTION_PAUSE = "pause"
        private const val ACTION_RECORD = "record"
        private const val ACTION_RECORD_STOP = "record_stop"
        private const val ACTION_STOP_FROM_NOTIF = "record_stop_notif"
        private const val ACTION_COMMAND = "command_next"
        @Volatile var enabled = false
        @Volatile var running = false; private set
        @Volatile var isRecording = false; private set
        @Volatile private var commandPending = false

        fun enable(ctx: Context, on: Boolean) {
            enabled = on
            val i = Intent(ctx, WakeWordService::class.java)
            if (on) {
                if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                    enabled = false
                    return
                }
                try { ctx.startForegroundService(i) } catch (e: Exception) {
                    android.util.Log.e(TAG, "startForegroundService failed: ${e.javaClass.simpleName}")
                    enabled = false
                }
            } else if (!isRecording) {
                try { ctx.stopService(i) } catch (_: Exception) {}
            }
        }

        /** Meeting audio on (op "meeting_audio" from the runtime). Works while Snapy is visible
         *  or the service already runs in the foreground (wake word on). */
        fun startRecording(ctx: Context, id: String, path: String): Boolean = try {
            // Without RECORD_AUDIO a startForegroundService() could never reach startForeground(type
            // microphone) -> Android kills the app ("did not then call startForeground"). Refuse here.
            if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED)
                throw SecurityException("no RECORD_AUDIO")
            val i = Intent(ctx, WakeWordService::class.java).setAction(ACTION_RECORD).putExtra("id", id).putExtra("path", path)
            // already a foreground service (wake word on): a plain start is allowed from the
            // background and keeps its while-in-use mic access; else it must start from the UI
            if (running) ctx.startService(i) else ctx.startForegroundService(i)
            true
        } catch (e: Exception) {
            val (key, fallback) = if (e is SecurityException) "meeting.need_mic" to "Snapy needs the microphone to record the meeting."
                else "meeting.open_app" to "Open Snapy to start recording — Android only allows it while Snapy is on screen."
            CoreBridge.get(ctx).publish(JSONObject().put("type", "toast").put("text",
                Strings.t(ctx, key).let { if (it == key) fallback else it }))
            CoreBridge.get(ctx).call("meeting_audio_saved", id, "", "0") { }
            false
        }

        fun stopRecording(ctx: Context) {
            if (!isRecording) return
            try { ctx.startService(Intent(ctx, WakeWordService::class.java).setAction(ACTION_RECORD_STOP)) } catch (_: Exception) { }
        }

        /** While recording, an activation makes the next phrase a command (no second mic user). */
        fun commandNext(ctx: Context) {
            commandPending = true
            CameraCapsule.captions.show(ctx, Strings.t(ctx, "chip.listening"), CameraCapsule.RECORDING, 6000)
        }

        fun pause(ctx: Context) { if (enabled && !isRecording) try { ctx.startService(Intent(ctx, WakeWordService::class.java).setAction(ACTION_PAUSE)) } catch (_: Exception) { } }
        fun resume(ctx: Context) { if (enabled && !isRecording) try { ctx.startService(Intent(ctx, WakeWordService::class.java)) } catch (_: Exception) { } }
    }
}
