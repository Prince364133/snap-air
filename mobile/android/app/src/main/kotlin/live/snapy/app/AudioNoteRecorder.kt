package live.snapy.app

import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Silent, high-fidelity audio note recorder (like ChatGPT and WhatsApp).
 * Starts recording instantly without annoying Google SpeechRecognizer beeps or error 13 chimes.
 * Saves audio directly to the Conscious Vault.
 */
object AudioNoteRecorder {
    private const val TAG = "AudioNoteRecorder"
    private val main = Handler(Looper.getMainLooper())
    private var recorder: MediaRecorder? = null
    private var currentFile: File? = null
    private var startTimestamp = 0L

    @Volatile var isRecording = false
        private set

    var onTimerTick: ((elapsedSeconds: Int) -> Unit)? = null

    private val timerRunnable = object : Runnable {
        override fun run() {
            if (!isRecording) return
            val elapsed = ((System.currentTimeMillis() - startTimestamp) / 1000L).toInt()
            onTimerTick?.invoke(elapsed)
            main.postDelayed(this, 1000L)
        }
    }

    fun start(ctx: Context): Boolean {
        if (isRecording) return true
        return try {
            val vaultDir = File(ctx.filesDir, "vault/notes").apply { mkdirs() }
            val timeStamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
            val file = File(vaultDir, "note_$timeStamp.m4a")
            currentFile = file

            val r = if (Build.VERSION.SDK_INT >= 31) {
                MediaRecorder(ctx)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioEncodingBitRate(128000)
            r.setAudioSamplingRate(44100)
            r.setOutputFile(file.absolutePath)
            r.prepare()
            r.start()

            recorder = r
            isRecording = true
            startTimestamp = System.currentTimeMillis()
            main.post(timerRunnable)
            Log.d(TAG, "Audio note recording started silently: ${file.absolutePath}")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start silent audio recording", e)
            isRecording = false
            try { recorder?.release() } catch (_: Exception) {}
            recorder = null
            false
        }
    }

    fun stop(ctx: Context): File? {
        if (!isRecording) return null
        isRecording = false
        main.removeCallbacks(timerRunnable)
        return try {
            recorder?.stop()
            recorder?.release()
            recorder = null
            val file = currentFile
            if (file != null && file.exists() && file.length() > 0) {
                val elapsed = ((System.currentTimeMillis() - startTimestamp) / 1000L).toInt()
                Log.d(TAG, "Audio note saved: ${file.absolutePath} ($elapsed s)")

                val event = JSONObject().apply {
                    put("type", "audio_note")
                    put("path", file.absolutePath)
                    put("name", file.name)
                    put("duration_s", elapsed)
                    put("timestamp", System.currentTimeMillis())
                }
                CoreBridge.get(ctx.applicationContext).publish(event)
                file
            } else {
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping audio recorder", e)
            try { recorder?.release() } catch (_: Exception) {}
            recorder = null
            null
        }
    }
}

