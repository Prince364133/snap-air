package live.snapy.app

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * Dart <-> Android, used by the main screen and the bottom sheet over other apps:
 *   "snapy/core"   (methods)  send a message, settings, keys, lists, Real Count, permissions
 *   "snapy/events" (stream)   everything the shared brain emits (chat, state, toasts…)
 */
object SnapyChannels {
    fun register(engine: FlutterEngine, activity: Activity) {
        val core = CoreBridge.get(activity.applicationContext)
        val usage = UsageTracker(activity)
        val messenger = engine.dartExecutor.binaryMessenger

        EventChannel(messenger, "snapy/events").setStreamHandler(object : EventChannel.StreamHandler {
            private var listener: ((String) -> Unit)? = null
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                listener = { batch: String -> sink.success(batch) }.also { core.addListener(it) }
            }
            override fun onCancel(args: Any?) {
                listener?.let { core.removeListener(it) }
                listener = null
            }
        })

        MethodChannel(messenger, "snapy/core").setMethodCallHandler { call, result ->
            fun str(k: String) = call.argument<String>(k) ?: ""
            when (call.method) {
                "ready" -> result.success(core.isReady())
                "send" -> { core.send(str("text"), call.argument<String>("source") ?: "typed"); result.success(true) }
                "interrupt" -> { core.interrupt(); result.success(true) }
                "setApiKey" -> core.call("set_api_key", str("provider"), str("key")) { result.success(it) }
                "brainStatus" -> core.call("brain_status_json") { result.success(it) }
                "updateSettings" -> core.call("update_settings", str("json")) { result.success(it) }
                "snapshot" -> core.call("snapshot") { result.success(it) }
                "completeTask" -> core.call("complete_task", str("id")) { result.success(it) }
                "config" -> core.configAsync(str("path")) { result.success(it) }
                "status" -> result.success(mapOf(
                    "usage" to usage.hasAccess(),
                    "realcount" to isAccessibilityOn(activity),
                    "pill" to (SnapyAccessibilityService.instance != null),
                    "microphone" to (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED),
                    "contacts" to (activity.checkSelfPermission(Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED),
                    "calls" to (activity.checkSelfPermission(Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED),
                    "wake" to WakeWordService.enabled,
                    "notifications" to (Build.VERSION.SDK_INT < 33 ||
                        activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED),
                ))
                "requestNotifications" -> {
                    if (Build.VERSION.SDK_INT >= 33) activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 41)
                    result.success(true)
                }
                "openUsageAccess" -> { activity.startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)); result.success(true) }
                "openRealCountSettings" -> { activity.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)); result.success(true) }
                "today" -> Thread {
                    val t = usage.today()
                    val rc = SnapyAccessibilityService.instance?.todayJson() ?: RealCountStore(activity).today()
                    val perApp = JSONObject()
                    t.perApp.entries.sortedByDescending { it.value }.take(30).forEach { perApp.put(it.key, it.value) }
                    val out = JSONObject().put("screen_ms", t.totalMs).put("per_app_ms", perApp)
                        .put("opens", JSONObject(t.opens as Map<*, *>)).put("realcount", rc)
                    activity.runOnUiThread { result.success(out.toString()) }
                }.start()
                "closeSheet" -> { activity.finish(); result.success(true) }
                // ---- voice
                "startListening" -> {
                    if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 42)
                        result.success(false)
                    } else { VoiceController.start(activity, "voice"); result.success(true) }
                }
                "stopListening" -> { VoiceController.stop(); result.success(true) }
                "requestPermission" -> {
                    val perm = when (str("which")) {
                        "contacts" -> Manifest.permission.READ_CONTACTS
                        "calls" -> Manifest.permission.CALL_PHONE
                        "microphone" -> Manifest.permission.RECORD_AUDIO
                        else -> null
                    }
                    if (perm != null) activity.requestPermissions(arrayOf(perm), 43)
                    result.success(perm != null)
                }
                "setWakeWord" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    if (on && activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 42)
                        result.success(false)
                    } else {
                        core.call("update_settings", JSONObject().put("android_wake_word", on).toString()) {
                            WakeWordService.enable(activity.applicationContext, on)   // started while Snapy is open
                            result.success(true)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun isAccessibilityOn(activity: Activity): Boolean {
        val enabled = Settings.Secure.getString(activity.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        val me = ComponentName(activity, SnapyAccessibilityService::class.java).flattenToString()
        return enabled.split(':').any { it.equals(me, ignoreCase = true) }
    }
}
