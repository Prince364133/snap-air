package live.snapy.app

import android.content.Context
import android.speech.tts.TextToSpeech
import java.util.Locale
import java.util.UUID

/**
 * Snapy's voice on Android: the phone's own TextToSpeech, which includes natural
 * native-speaker voices for Hindi, Tamil, Telugu, Bengali, Marathi and more
 * (and is licensed for commercial use with the device).
 */
class Speech(ctx: Context) : TextToSpeech.OnInitListener {
    private val tts = TextToSpeech(ctx.applicationContext, this)
    private var ready = false
    private val pending = mutableListOf<Pair<String, String>>()

    override fun onInit(status: Int) {
        ready = status == TextToSpeech.SUCCESS
        if (ready) synchronized(pending) { pending.forEach { speak(it.first, it.second) }; pending.clear() }
    }

    fun speak(text: String, lang: String) {
        if (!ready) { synchronized(pending) { pending.add(text to lang) }; return }
        val locale = when (lang.take(2)) {
            "hi" -> Locale.forLanguageTag("hi-IN")
            "en" -> Locale.forLanguageTag("en-IN")
            else -> Locale.forLanguageTag("${lang.take(2)}-IN")
        }
        if (tts.isLanguageAvailable(locale) >= TextToSpeech.LANG_AVAILABLE) tts.language = locale
        tts.speak(text, TextToSpeech.QUEUE_ADD, null, UUID.randomUUID().toString())
    }

    fun stop() { tts.stop() }

    fun isSpeaking() = ready && tts.isSpeaking
}
