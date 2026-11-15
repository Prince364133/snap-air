package live.snapy.app

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.chaquo.python.PyObject
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

/**
 * The one Snapy brain (engine/src, shared with Windows) running in-process via Chaquopy.
 *  - Calls into Python run on one worker thread, in order.
 *  - An event pump drains the brain's events and routes them:
 *      op -> OpExecutor (phone actions) · speak -> Android TTS · reminders -> AlarmManager
 *      everything -> Flutter listeners (chat, state, toasts…)
 */
class CoreBridge private constructor(private val ctx: Context) {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var core: PyObject? = null
    private var appdata: PyObject? = null
    private val listeners = CopyOnWriteArrayList<(String) -> Unit>()
    private val executor = OpExecutor(ctx)
    private val speech by lazy { Speech(ctx) }

    init {
        worker.execute {
            if (!Python.isStarted()) Python.start(AndroidPlatform(ctx))
            val py = Python.getInstance()
            val module = py.getModule("src.platform.android")
            module.callAttr("init", ctx.filesDir.absolutePath + "/snapy", KeyCipher())
            core = module.callAttr("core")
            appdata = py.getModule("src.appdata")
            core!!.callAttr("set_apps", installedApps().toString())
            Thread({ pump() }, "snapy-events").start()
        }
    }

    fun isReady() = core != null

    /** Flutter screens subscribe to the brain's events (JSON list per batch). */
    fun addListener(l: (String) -> Unit) = listeners.add(l)
    fun removeListener(l: (String) -> Unit) = listeners.remove(l)

    private fun pump() {
        while (true) {
            val batch = try { core?.callAttr("next_events", 1.0)?.toString() ?: "[]" } catch (e: Exception) { "[]" }
            val events = JSONArray(batch)
            if (events.length() == 0) continue
            main.post {
                for (i in 0 until events.length()) route(events.getJSONObject(i))
                listeners.forEach { it(batch) }
            }
        }
    }

    private fun route(e: JSONObject) {
        when (e.optString("type")) {
            "op" -> executor.runOp(e)
            "speak" -> speech.speak(e.optString("text"), e.optString("lang", "en"))
            "speak_stop" -> speech.stop()
            "reminders" -> { Reminders.ensureChannel(ctx); Reminders.sync(ctx, e.optJSONArray("items") ?: JSONArray()) }
        }
    }

    // ---------------------------------------------------------------- calls from Flutter
    fun send(text: String, source: String = "typed") = worker.execute { core?.callAttr("send", text, source) }
    fun interrupt() = worker.execute { core?.callAttr("interrupt") }

    fun call(method: String, vararg args: Any?, done: (String) -> Unit) = worker.execute {
        val v = try { core?.callAttr(method, *args)?.toString() ?: "null" } catch (e: Exception) { JSONObject().put("error", e.message).toString() }
        main.post { done(v) }
    }

    fun reminderFired(id: String) = worker.execute { core?.callAttr("reminder_fired", id) }

    /** Central data (src/data/app.json) for Kotlin and Dart: no copies, no hardcoding. */
    fun configAsync(path: String, done: (String) -> Unit) = worker.execute {
        val v = py().getModule("json").callAttr("dumps", appdata?.callAttr("get", path)).toString()
        main.post { done(v) }
    }

    fun configNow(path: String): String = worker.submit<String> {
        py().getModule("json").callAttr("dumps", appdata?.callAttr("get", path)).toString()
    }.get()

    private fun py() = Python.getInstance()

    /** Launchable apps (needs the LAUNCHER <queries> entry, not QUERY_ALL_PACKAGES). */
    private fun installedApps(): JSONArray {
        val pm = ctx.packageManager
        val main = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val out = JSONArray()
        for (ri in pm.queryIntentActivities(main, 0)) {
            out.put(JSONObject().put("label", ri.loadLabel(pm).toString()).put("package", ri.activityInfo.packageName))
        }
        return out
    }

    companion object {
        @Volatile private var instance: CoreBridge? = null
        fun get(ctx: Context) = instance ?: synchronized(this) { instance ?: CoreBridge(ctx.applicationContext).also { instance = it } }
    }
}
