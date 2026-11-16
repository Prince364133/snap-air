package live.snapy.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock

/** MIRROR of CaptionClock in lib/core_runtime/phone_services.dart (test/phone_services_test.dart). */
class CaptionClock(val fadeMs: Long = 2000, val thinkingMs: Long = 8000) {
    var text = ""; private set
    var hideAt = 0L; private set
    var speaking = false; private set

    fun voice(state: String, t: String, now: Long) {
        when (state) {
            "listening", "partial" -> { if (t.isNotBlank()) text = t.trim(); hideAt = now + fadeMs + if (state == "listening") 4000 else 0 }
            "thinking" -> { if (t.isNotBlank()) text = t.trim(); hideAt = now + thinkingMs }
            "idle", "error" -> if (!speaking) hideAt = now + fadeMs
        }
    }

    fun speak(t: String, now: Long) {
        if (t.isBlank()) return
        text = t.trim(); speaking = true
        hideAt = now + speakMs(text) + fadeMs
    }

    fun speechDone(now: Long) { speaking = false; hideAt = now + fadeMs }

    fun visible(now: Long) = text.isNotEmpty() && now < hideAt

    companion object {
        fun speakMs(text: String): Long = maxOf(1200L, text.trim().split(Regex("\\s+")).count { it.isNotEmpty() } * 380L)
    }
}

/**
 * The caption capsule under the camera (§6), driven by the same events as the UI:
 * {"type":"voice", state, text, level} (VoiceController / the meeting recorder) and
 * {"type":"speak", text} (CoreBridge). Fades 2 s after speech ends.
 * When the owner's island chip is on screen it already shows a subtitle for voice states, so
 * voice text goes there and only Snapy's spoken replies are routed to it (no double capsule).
 */
object Captions {
    private val main = Handler(Looper.getMainLooper())
    private val clock = CaptionClock()
    private val tick = Runnable { check() }

    private fun now() = SystemClock.uptimeMillis()

    fun onVoice(ctx: Context, state: String, text: String, level: Float = 0f) = main.post {
        if (state == "level") {
            CameraCapsule.captions.level(level)
            RealCountController.active?.micLevel(level)
            return@post
        }
        clock.voice(state, text, now())
        if (RealCountController.active?.chipShown == true) return@post         // the chip's subtitle shows it
        render(ctx)
    }

    fun onSpeak(ctx: Context, text: String) = main.post {
        clock.speak(text, now())
        if (RealCountController.active?.subtitle(clock.text) == true) return@post
        render(ctx)
    }

    fun speechDone() = main.post { clock.speechDone(now()); schedule() }

    private fun render(ctx: Context) {
        if (clock.text.isEmpty()) return
        CameraCapsule.captions.show(ctx, clock.text, if (clock.speaking) CameraCapsule.ACCENT else CameraCapsule.TEXT)
        schedule()
    }

    private fun schedule() {
        main.removeCallbacks(tick)
        main.postDelayed(tick, (clock.hideAt - now()).coerceAtLeast(50))
    }

    private fun check() {
        if (clock.visible(now())) schedule() else CameraCapsule.captions.dismiss()
    }
}
