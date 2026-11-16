package live.snapy.app

import android.content.Context
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Snapy's voice on Android: the phone's own TextToSpeech, which includes natural
 * native-speaker voices for Hindi, Tamil, Telugu, Bengali, Marathi and more
 * (and is licensed for commercial use with the device).
 * When an utterance ends: [onAnyDone] (captions fade 2 s later) and the caller's callback
 * (the wake greeting, then listening).
 */
class Speech(ctx: Context, private val onAnyDone: () -> Unit = {}) : TextToSpeech.OnInitListener {
    private val tts = TextToSpeech(ctx.applicationContext, this)
    private var ready = false
    private val pending = mutableListOf<Triple<String, String, (() -> Unit)?>>()
    private val callbacks = ConcurrentHashMap<String, () -> Unit>()

    override fun onInit(status: Int) {
        ready = status == TextToSpeech.SUCCESS
        if (ready) {
            tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(id: String?) {}
                override fun onDone(id: String?) = finished(id)
                @Deprecated("old callback") override fun onError(id: String?) = finished(id)
                override fun onError(id: String?, errorCode: Int) = finished(id)
                override fun onStop(id: String?, interrupted: Boolean) = finished(id)
            })
            synchronized(pending) { pending.forEach { speak(it.first, it.second, it.third) }; pending.clear() }
        } else synchronized(pending) { pending.forEach { it.third?.let { cb -> CoreBridge.mainHandler.post(cb) } }; pending.clear() }
    }

    private fun finished(id: String?) {
        val cb = id?.let { callbacks.remove(it) }
        CoreBridge.mainHandler.post { onAnyDone(); cb?.invoke() }
    }

    fun speak(text: String, lang: String, onDone: (() -> Unit)? = null) {
        if (!ready) { synchronized(pending) { pending.add(Triple(text, lang, onDone)) }; return }
        val locale = when (lang.take(2)) {
            "hi" -> Locale.forLanguageTag("hi-IN")
            "en" -> Locale.forLanguageTag("en-IN")
            else -> Locale.forLanguageTag("${lang.take(2)}-IN")
        }
        if (tts.isLanguageAvailable(locale) >= TextToSpeech.LANG_AVAILABLE) tts.language = locale
        val id = UUID.randomUUID().toString()
        if (onDone != null) callbacks[id] = onDone
        if (tts.speak(text, TextToSpeech.QUEUE_ADD, null, id) != TextToSpeech.SUCCESS) finished(id)
    }

    fun stop() { tts.stop() }

    fun isSpeaking() = ready && tts.isSpeaking
}
