package live.snapy.app

import android.app.Activity
import android.app.Application
import android.os.Bundle
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.GenerativeModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** Is one of Snapy's activities started (Snapy is the app on screen)? */
object AppForeground : Application.ActivityLifecycleCallbacks {
    @Volatile private var started = 0
    @Volatile private var installed = false
    val isForeground get() = started > 0

    fun install(app: Application) {
        if (installed) return
        installed = true
        app.registerActivityLifecycleCallbacks(this)
    }

    override fun onActivityStarted(a: Activity) { started++ }
    override fun onActivityStopped(a: Activity) { if (started > 0) started-- }
    override fun onActivityCreated(a: Activity, b: Bundle?) {}
    override fun onActivityResumed(a: Activity) {}
    override fun onActivityPaused(a: Activity) {}
    override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
    override fun onActivityDestroyed(a: Activity) {}
}

/**
 * Gemini Nano on the phone through the ML Kit GenAI Prompt API (com.google.mlkit:genai-prompt).
 * AICore only allows inference while the app is the top foreground app (otherwise
 * BACKGROUND_USE_BLOCKED), so every call checks [AppForeground] first and answers
 * "background" — the Dart brain router then uses the next brain (cloud key / laptop).
 * Status: available | downloadable | downloading | unavailable | background.
 * Needs on-device verification (only some phones have Gemini Nano; not on unlocked bootloaders).
 */
object GeminiNano {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val model: GenerativeModel? by lazy { try { Generation.getClient() } catch (_: Throwable) { null } }
    @Volatile private var downloading = false

    fun status(done: (String) -> Unit) {
        if (!AppForeground.isForeground) { done("background"); return }
        scope.launch {
            val s = try {
                when (model?.checkStatus()) {
                    FeatureStatus.AVAILABLE -> "available"
                    FeatureStatus.DOWNLOADING -> "downloading"
                    FeatureStatus.DOWNLOADABLE -> { startDownload(); "downloadable" }
                    else -> "unavailable"
                }
            } catch (_: Throwable) { "unavailable" }
            CoreBridge.mainHandler.post { done(s) }
        }
    }

    /** The model is fetched by AICore (not part of the APK); started once, while Snapy is open. */
    private fun startDownload() {
        if (downloading) return
        downloading = true
        scope.launch {
            try { model?.download()?.collect { } } catch (_: Throwable) { } finally { downloading = false }
        }
    }

    fun generate(prompt: String, onChunk: (String) -> Unit, onDone: (String?) -> Unit) {
        val m = model
        if (m == null) { onDone("unavailable"); return }
        if (!AppForeground.isForeground) { onDone("background"); return }
        scope.launch {
            try {
                m.generateContentStream(prompt).collect { chunk ->
                    val t = chunk.candidates.firstOrNull()?.text
                    if (!t.isNullOrEmpty()) CoreBridge.mainHandler.post { onChunk(t) }
                }
                CoreBridge.mainHandler.post { onDone(null) }
            } catch (e: Throwable) {
                CoreBridge.mainHandler.post { onDone(e.javaClass.simpleName) }
            }
        }
    }
}
