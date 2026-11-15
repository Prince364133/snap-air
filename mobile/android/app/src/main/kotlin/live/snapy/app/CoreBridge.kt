package live.snapy.app

import android.app.Application
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Snapy's brain: the Dart core runtime (lib/core_runtime, implementing core/ like the Windows
 * Python engine) in ONE headless FlutterEngine per process, started here and cached in
 * FlutterEngineCache as [ENGINE_ID]. That engine owns every store — the single source of truth.
 *
 *  - Kotlin and the UI engines call it over "snapy/runtime" ("call" {method, args}); calls made
 *    before it is up are queued and run in order.
 *  - Its events arrive as batches ("events") and are routed:
 *      op -> OpExecutor (phone actions) · speak -> Android TTS · reminders -> AlarmManager
 *      everything -> Flutter UI listeners ("snapy/events")
 *  - It asks Kotlin for contacts, Gemini Nano, Wi-Fi state and the multicast lock.
 * The public API is the one the Chaquopy bridge had, so callers barely changed.
 */
class CoreBridge private constructor(private val ctx: Context) {
    private val listeners = CopyOnWriteArrayList<(String) -> Unit>()
    private val executor by lazy { OpExecutor(ctx) }
    private val speech by lazy { Speech(ctx) }
    private val contacts by lazy { Contacts(ctx) }
    private var channel: MethodChannel? = null
    @Volatile private var ready = false
    private val queue = ArrayList<() -> Unit>()          // main thread only
    private var multicast: WifiManager.MulticastLock? = null

    init {
        (ctx as? Application)?.let { AppForeground.install(it) }
        onMain { startEngine() }
    }

    private fun startEngine() {
        val cache = FlutterEngineCache.getInstance()
        val engine = cache.get(ENGINE_ID) ?: run {
            val loader = FlutterInjector.instance().flutterLoader()
            if (!loader.initialized()) loader.startInitialization(ctx)
            loader.ensureInitializationComplete(ctx, null)
            FlutterEngine(ctx).also { e ->
                cache.put(ENGINE_ID, e)
                channel = MethodChannel(e.dartExecutor.binaryMessenger, "snapy/runtime").also { it.setMethodCallHandler(::onDart) }
                SecureFiles.register(e.dartExecutor.binaryMessenger, ctx)
                // the entrypoint lives in lib/main.dart (@pragma('vm:entry-point') snapyCoreMain)
                e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "snapyCoreMain"))
            }
        }
        if (channel == null) channel = MethodChannel(engine.dartExecutor.binaryMessenger, "snapy/runtime").also { it.setMethodCallHandler(::onDart) }
    }

    // ---------------------------------------------------------------- calls from Dart
    private fun onDart(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ready" -> {
                result.success(true)
                channel?.invokeMethod("init", mapOf("dataDir" to ctx.filesDir.absolutePath + "/snapy"), object : MethodChannel.Result {
                    override fun success(r: Any?) = onReady()
                    override fun error(code: String, msg: String?, details: Any?) { publish(JSONObject().put("type", "toast").put("text", "Snapy's brain didn't start: $code")) }
                    override fun notImplemented() {}
                })
            }
            "events" -> { onEvents(call.arguments as? String ?: "[]"); result.success(null) }
            "contacts" -> {
                val name = call.argument<String>("name") ?: ""
                Thread { val r = try { contacts.find(name) } catch (_: Exception) { "[]" }; mainHandler.post { result.success(r) } }.start()
            }
            "nanoStatus" -> GeminiNano.status { result.success(it) }
            "nanoGenerate" -> {
                val id = call.argument<Int>("id") ?: 0
                result.success(true)
                GeminiNano.generate(call.argument<String>("prompt") ?: "",
                    onChunk = { t -> channel?.invokeMethod("nanoChunk", mapOf("id" to id, "text" to t)) },
                    onDone = { err -> channel?.invokeMethod("nanoDone", mapOf("id" to id, "error" to err)) })
            }
            "onWifi" -> result.success(onWifi())
            "multicastLock" -> { multicastLock(call.argument<Boolean>("on") ?: false); result.success(true) }
            else -> result.notImplemented()
        }
    }

    private fun onReady() {
        ready = true
        val pending = ArrayList(queue)
        queue.clear()
        pending.forEach { it() }
        Thread { val apps = installedApps().toString(); call("set_apps", apps) { } }.start()
    }

    private fun onEvents(batch: String) {
        val events = try { JSONArray(batch) } catch (_: Exception) { return }
        if (events.length() == 0) return
        for (i in 0 until events.length()) route(events.getJSONObject(i))
        listeners.forEach { it(batch) }
    }

    private fun route(e: JSONObject) {
        when (e.optString("type")) {
            "op" -> executor.runOp(e)
            "speak" -> speech.speak(e.optString("text"), e.optString("lang", "en"))
            "speak_stop" -> speech.stop()
            "reminders" -> { Reminders.ensureChannel(ctx); Reminders.sync(ctx, e.optJSONArray("items") ?: JSONArray()) }
        }
    }

    private fun onWifi(): Boolean = try {
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        cm.getNetworkCapabilities(cm.activeNetwork)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
    } catch (_: Exception) { false }

    /** mDNS / beacon replies are dropped on many phones without a multicast lock (only while searching). */
    private fun multicastLock(on: Boolean) {
        try {
            if (on) {
                val wm = ctx.getSystemService(Context.WIFI_SERVICE) as WifiManager
                multicast = (multicast ?: wm.createMulticastLock("snapy-sync").apply { setReferenceCounted(false) }).also { it.acquire() }
            } else multicast?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) { }
    }

    // ---------------------------------------------------------------- API (unchanged for callers)
    fun isReady() = ready

    /** Flutter screens subscribe to the brain's events (JSON list per batch). */
    fun addListener(l: (String) -> Unit) = listeners.add(l)
    fun removeListener(l: (String) -> Unit) = listeners.remove(l)

    private fun whenReady(block: () -> Unit) = onMain { if (ready) block() else queue.add(block) }

    /** A runtime method by name; [done] gets the text result on the main thread. */
    fun call(method: String, vararg args: Any?, done: (String) -> Unit) {
        val list = args.map { it?.toString() ?: "" }
        whenReady {
            val ch = channel ?: return@whenReady done("null")
            ch.invokeMethod("call", mapOf("method" to method, "args" to list), object : MethodChannel.Result {
                override fun success(r: Any?) = done(r as? String ?: "null")
                override fun error(code: String, msg: String?, details: Any?) = done(JSONObject().put("error", msg ?: code).toString())
                override fun notImplemented() = done("null")
            })
        }
    }

    /** Blocking variant for background threads only (returns null on the main thread or after [timeoutMs]). */
    fun callBlocking(method: String, vararg args: Any?, timeoutMs: Long = 4000): String? {
        if (Looper.myLooper() == Looper.getMainLooper()) return null
        val latch = CountDownLatch(1)
        var out: String? = null
        call(method, *args) { out = it; latch.countDown() }
        return if (latch.await(timeoutMs, TimeUnit.MILLISECONDS)) out else null
    }

    fun send(text: String, source: String = "typed") = call("send", text, source) { }
    fun interrupt() = call("interrupt") { }
    fun reminderFired(id: String) = call("reminder_fired", id) { }

    /** Screen taps: the shared matcher (same as Windows) picks a node. */
    fun findOnScreen(query: String, nodes: String, done: (Int) -> Unit) = call("find_on_screen", query, nodes) { r ->
        done(try { JSONObject(r).optInt("index", -1) } catch (_: Exception) { -1 })
    }

    // ---------------------------------------------------------------- voice
    fun stopSpeaking() = speech.stop()

    /** Recognizer locale, wake phrases, pause timing ({} until the brain is up). */
    fun voiceConfig(done: (JSONObject) -> Unit) = call("voice_config") { done(try { JSONObject(it) } catch (_: Exception) { JSONObject() }) }

    /** Old synchronous call (background threads only): small answers such as voice_config. */
    fun configNowCall(method: String): String = callBlocking(method) ?: "{}"

    /** Same pause logic as Windows: "open youtube and…" waits for the rest of the sentence. */
    fun isUnfinished(text: String, done: (Boolean) -> Unit) = call("sounds_unfinished", text) { done(it.trim() == "true") }

    /** Native events (voice, downloads…) go to the same Flutter stream as the brain's. */
    fun publish(e: JSONObject) {
        val batch = JSONArray().put(e).toString()
        onMain { listeners.forEach { it(batch) } }
    }

    /** Shared product data (core/rules, merged) for Kotlin and Dart: no copies, no hardcoding. */
    fun configAsync(path: String, done: (String) -> Unit) = onMain { done(CoreConfig.json(ctx, path)) }

    fun configNow(path: String): String = CoreConfig.json(ctx, path)

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
        const val ENGINE_ID = "snapy_core"
        val mainHandler = Handler(Looper.getMainLooper())

        fun onMain(block: () -> Unit) {
            if (Looper.myLooper() == Looper.getMainLooper()) block() else mainHandler.post(block)
        }

        @Volatile private var instance: CoreBridge? = null
        fun get(ctx: Context) = instance ?: synchronized(this) { instance ?: CoreBridge(ctx.applicationContext).also { instance = it } }
    }
}
