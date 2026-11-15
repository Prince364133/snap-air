package live.snapy.app

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import org.json.JSONObject

/**
 * One spoken turn: Android's speech recognizer (on-device/offline when the phone supports it),
 * live words, then the shared brain.
 *  - Barge-in: starting to listen stops Snapy's voice and its current answer.
 *  - Pauses: if what you said sounds unfinished ("open YouTube and…", same rule as Windows),
 *    it keeps listening and joins the next phrase into one command.
 * Voice events go to the Flutter UI and the Real Count pill:
 *   {"type":"voice","state":"listening|partial|thinking|idle|error","text":…,"level":…}
 */
object VoiceController {
    private val main = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var sofar = ""                       // text kept across a mid-sentence pause
    private var source = "voice"
    @Volatile var active = false
        private set

    fun start(ctx: Context, from: String = "voice") = main.post {
        val app = ctx.applicationContext
        val core = CoreBridge.get(app)
        core.stopSpeaking()                      // barge-in: the user is talking now
        core.interrupt()
        WakeWordService.pause(app)              // one microphone user at a time
        source = from
        sofar = ""
        listen(app)
    }

    fun stop() = main.post {
        recognizer?.stopListening()
    }

    private fun listen(app: Context, continuation: Boolean = false) {
        // voice_config comes from the Dart brain asynchronously (never block the main thread)
        CoreBridge.get(app).voiceConfig { cfg -> listen(app, cfg, continuation) }
    }

    private fun listen(app: Context, cfg: JSONObject, continuation: Boolean) {
        val core = CoreBridge.get(app)
        recognizer?.destroy()
        val onDevice = Build.VERSION.SDK_INT >= 33 && SpeechRecognizer.isOnDeviceRecognitionAvailable(app)
        val r = if (onDevice) SpeechRecognizer.createOnDeviceSpeechRecognizer(app) else SpeechRecognizer.createSpeechRecognizer(app)
        recognizer = r
        active = true
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE, cfg.optString("locale", "en-IN"))
            .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            .putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        if (continuation) {
            // after an unfinished phrase, wait a little longer for the rest
            intent.putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, cfg.optLong("continuation_wait_ms", 1500))
        }
        r.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(p: Bundle?) = emit(core, "listening", sofar)
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(db: Float) = emit(core, "level", sofar, level = ((db + 2f) / 12f).coerceIn(0f, 1f))
            override fun onBufferReceived(b: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onEvent(t: Int, p: Bundle?) {}

            override fun onPartialResults(p: Bundle?) {
                val part = p?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: return
                emit(core, "partial", join(sofar, part))
            }

            override fun onResults(p: Bundle?) {
                val said = p?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
                val text = join(sofar, said)
                if (text.isBlank() || continuation) { finish(app, text); return }
                core.isUnfinished(text) { unfinished ->
                    if (unfinished) {
                        sofar = text                                // "open YouTube and…" — keep listening
                        emit(core, "partial", "$text …")
                        main.postDelayed({ listen(app, cfg, continuation = true) }, 120)
                    } else finish(app, text)
                }
            }

            override fun onError(code: Int) {
                // a pause with nothing more said after an unfinished phrase: send what we have
                if (sofar.isNotBlank()) { finish(app, sofar); return }
                active = false
                if (code == 13 || code == SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED) {
                    android.util.Log.w("VoiceController", "Speech recognition code 13 (language unsupported) -> fallback to idle")
                    emit(core, "idle", "")
                    WakeWordService.resume(app)
                    return
                }
                emit(core, if (code == SpeechRecognizer.ERROR_NO_MATCH || code == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) "idle" else "error",
                    "", error = errorText(code))
                WakeWordService.resume(app)
            }
        })
        r.startListening(intent)
    }

    private fun finish(app: Context, text: String) {
        val core = CoreBridge.get(app)
        active = false
        sofar = ""
        if (text.isNotBlank()) {
            emit(core, "thinking", text)
            core.send(text, source)                          // spoken -> the brain answers out loud
        } else {
            emit(core, "idle", "")
        }
        WakeWordService.resume(app)
    }

    private fun join(a: String, b: String) = listOf(a.trim(), b.trim()).filter { it.isNotEmpty() }.joinToString(" ")

    private fun emit(core: CoreBridge, state: String, text: String, level: Float = 0f, error: String? = null) {
        val e = JSONObject().put("type", "voice").put("state", state).put("text", text).put("level", level.toDouble())
        if (error != null) e.put("error", error)
        core.publish(e)
        if (state != "level") SnapyAccessibilityService.instance?.showVoice(state, text)
    }

    private fun errorText(code: Int) = when (code) {
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Snapy needs microphone permission"
        SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Speech recognition needs internet on this phone"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "The microphone is busy"
        SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "I didn't catch that"
        else -> "Speech recognition error ($code)"
    }
}
