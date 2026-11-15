package live.snapy.app

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * Dart <-> Android, used by the main screen and the bottom sheet over other apps:
 *   "snapy/core"   (methods)  send a message, settings, keys, lists, Real Count, permissions
 *   "snapy/events" (stream)   everything the shared brain emits (chat, state, toasts…)
 *   "snapy/keystore" (methods) Keystore-backed secrets (SecureFiles)
 * Brain calls are forwarded to the Dart core engine (CoreBridge) — the UI never owns the stores.
 */
object SnapyChannels {
    fun register(engine: FlutterEngine, activity: Activity) {
        val core = CoreBridge.get(activity.applicationContext)
        val usage = UsageTracker(activity)
        val messenger = engine.dartExecutor.binaryMessenger
        SecureFiles.register(messenger, activity)          // Keystore-backed secrets (pairing, API keys)

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
                    "overlay" to Settings.canDrawOverlays(activity),
                    "realcount" to isAccessibilityOn(activity),
                    "pill" to (SnapyAccessibilityService.instance != null),
                    "microphone" to (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED),
                    "contacts" to (activity.checkSelfPermission(Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED),
                    "calls" to (activity.checkSelfPermission(Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED),
                    "wake" to WakeWordService.enabled,
                    "notifications" to (Build.VERSION.SDK_INT < 33 ||
                        activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED),
                    "battery" to (activity.getSystemService(android.content.Context.POWER_SERVICE) as PowerManager)
                        .isIgnoringBatteryOptimizations(activity.packageName),
                ))
                "requestNotifications" -> {
                    if (Build.VERSION.SDK_INT >= 33) activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 41)
                    result.success(true)
                }
                "openUsageAccess" -> {
                    val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    activity.startActivity(intent)
                    result.success(true)
                }
                "openOverlaySettings" -> {
                    var opened = false
                    try {
                        val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:" + activity.packageName))
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        activity.startActivity(intent)
                        opened = true
                    } catch (_: Exception) {}
                    if (!opened) {
                        try {
                            val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            activity.startActivity(intent)
                            opened = true
                        } catch (_: Exception) {}
                    }
                    if (!opened) {
                        try {
                            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + activity.packageName)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            activity.startActivity(intent)
                        } catch (_: Exception) {}
                    }
                    result.success(true)
                }
                "openAppDetails" -> {
                    try {
                        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + activity.packageName))
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        activity.startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ERR", e.message, null)
                    }
                }
                "openRealCountSettings" -> {
                    val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    activity.startActivity(intent)
                    result.success(true)
                }
                "isRestrictedSettings" -> {
                    if (Build.VERSION.SDK_INT >= 33) {
                        val appOps = activity.getSystemService(Context.APP_OPS_SERVICE) as? android.app.AppOpsManager
                        var isRestricted = false
                        try {
                            if (appOps != null) {
                                val mode = appOps.unsafeCheckOpNoThrow(
                                    "android:access_restricted_settings",
                                    android.os.Process.myUid(),
                                    activity.packageName
                                )
                                isRestricted = (mode != android.app.AppOpsManager.MODE_ALLOWED)
                            }
                        } catch (_: Exception) {}
                        result.success(isRestricted)
                    } else {
                        result.success(false)
                    }
                }
                "startChip" -> {
                    RcPrefs(activity).update(JSONObject().put("chip_enabled", true))
                    SnapyAccessibilityService.instance?.showPillPublic()
                    RealCountController.active?.reload()
                    result.success(SnapyAccessibilityService.instance != null || ChipService.startIfWanted(activity.applicationContext))
                }
                "stopChip" -> {
                    RcPrefs(activity).update(JSONObject().put("chip_enabled", false))
                    RealCountController.active?.stop()
                    ChipService.stop(activity)
                    result.success(true)
                }
                "isChipActive" -> {
                    val on = RcPrefs(activity).bool("chip_enabled", true)
                    val running = SnapyAccessibilityService.instance != null || ChipService.instance != null
                    result.success(on && running)
                }
                "getInstalledApps" -> Thread {
                    try {
                        val pm = activity.packageManager
                        val mainIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                        val resolves = pm.queryIntentActivities(mainIntent, 0)
                        val socialSet = setOf(
                            "com.instagram.android", "com.google.android.youtube", "com.snapchat.android",
                            "com.facebook.katana", "com.facebook.lite", "com.zhiliaoapp.musically",
                            "com.ss.android.ugc.trill", "com.twitter.android", "com.reddit.frontpage",
                            "com.whatsapp", "in.mohalla.video", "com.eterno.shortvideos"
                        )
                        val list = resolves.map { ri ->
                            val p = ri.activityInfo.packageName
                            val l = ri.loadLabel(pm).toString()
                            mapOf("package" to p, "label" to l, "is_social" to socialSet.contains(p))
                        }.sortedBy { (it["label"] as? String)?.lowercase() ?: "" }
                        activity.runOnUiThread { result.success(list) }
                    } catch (t: Throwable) {
                        activity.runOnUiThread { result.success(emptyList<Map<String, Any>>()) }
                    }
                }.start()
                "getAppIcon" -> Thread {
                    val pkg = str("package")
                    if (pkg.isEmpty()) {
                        activity.runOnUiThread { result.success(null) }
                        return@Thread
                    }
                    try {
                        val pm = activity.packageManager
                        val d = pm.getApplicationIcon(pkg)
                        val bmp = if (d is BitmapDrawable && d.bitmap != null && !d.bitmap.isRecycled) {
                            Bitmap.createScaledBitmap(d.bitmap, 96, 96, true)
                        } else {
                            val b = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
                            val cv = Canvas(b)
                            d.setBounds(0, 0, 96, 96)
                            d.draw(cv)
                            b
                        }
                        val stream = ByteArrayOutputStream()
                        bmp.compress(Bitmap.CompressFormat.PNG, 90, stream)
                        val bytes = stream.toByteArray()
                        activity.runOnUiThread { result.success(bytes) }
                    } catch (_: Throwable) {
                        activity.runOnUiThread { result.success(null) }
                    }
                }.start()
                "today" -> Thread {
                    try {
                        val t = usage.today()
                        val rc = SnapyAccessibilityService.instance?.todayJson() ?: RealCountStore(activity).today()
                        val perApp = JSONObject()
                        t.perApp.entries.sortedByDescending { it.value }.take(30).forEach { perApp.put(it.key, it.value) }
                        val opensObj = JSONObject()
                        t.opens.forEach { (k, v) -> opensObj.put(k, v) }
                        val out = JSONObject()
                            .put("screen_ms", t.totalMs)
                            .put("per_app_ms", perApp)
                            .put("opens", opensObj)
                            .put("realcount", rc)
                        activity.runOnUiThread {
                            if (!activity.isFinishing && !activity.isDestroyed) {
                                result.success(out.toString())
                            }
                        }
                    } catch (t: Throwable) {
                        android.util.Log.e("SnapyChannels", "Error calculating today usage", t)
                        activity.runOnUiThread {
                            if (!activity.isFinishing && !activity.isDestroyed) {
                                val empty = JSONObject().put("screen_ms", 0L).put("per_app_ms", JSONObject()).put("opens", JSONObject()).put("realcount", JSONObject())
                                result.success(empty.toString())
                            }
                        }
                    }
                }.start()
                "closeSheet" -> {
                    if (activity is SheetActivity) {
                        activity.finish()
                    }
                    result.success(true)
                }
                // ---- Real Count (Phase 5): prefs, focus, brain calls, battery guide
                "filesDir" -> result.success(activity.filesDir.absolutePath)
                "rcPrefs" -> result.success(RcPrefs(activity).prefsJson().toString())
                "setRcPrefs" -> {
                    RcPrefs(activity).update(JSONObject(str("json")))
                    Strings.reload()
                    RealCountController.active?.reload()
                    result.success(true)
                }
                "rcState" -> result.success((RealCountController.active?.stateJson() ?: JSONObject().put("mode", "off")
                    .put("focus_until", RcPrefs(activity).long(RcPrefs.FOCUS_UNTIL))).toString())
                "startFocus" -> {
                    val min = call.argument<Int>("minutes") ?: 25
                    val c = RealCountController.active
                    if (c != null) c.startFocus(min) else RcPrefs(activity).putLong(RcPrefs.FOCUS_UNTIL, System.currentTimeMillis() + min * 60000L)
                    result.success(true)
                }
                "stopFocus" -> { RcPrefs(activity).putLong(RcPrefs.FOCUS_UNTIL, 0); RealCountController.active?.render(); result.success(true) }
                "pauseCounting" -> {
                    RcPrefs(activity).putLong(RcPrefs.PAUSED_UNTIL, System.currentTimeMillis() + (call.argument<Int>("minutes") ?: 60) * 60000L)
                    result.success(true)
                }
                "coreCall" -> {
                    val args = call.argument<List<String>>("args") ?: emptyList()
                    core.call(str("method"), *args.toTypedArray()) { result.success(it) }
                }
                "device" -> result.success(mapOf(
                    "manufacturer" to Build.MANUFACTURER, "brand" to Build.BRAND, "model" to Build.MODEL,
                    "sdk" to Build.VERSION.SDK_INT,
                    "snapy_version" to (try { activity.packageManager.getPackageInfo(activity.packageName, 0).versionName } catch (_: Exception) { "" }),
                ))
                "appVersions" -> {
                    val out = HashMap<String, String>()
                    for (p in call.argument<List<String>>("packages") ?: emptyList()) {
                        try { out[p] = activity.packageManager.getPackageInfo(p, 0).versionName ?: "" } catch (_: Exception) { }
                    }
                    result.success(out)
                }
                "openTarget" -> {
                    val pkg = call.argument<String>("pkg"); val cls = call.argument<String>("cls"); val action = call.argument<String>("action")
                    val i = when {
                        pkg != null && cls != null -> Intent().setComponent(ComponentName(pkg, cls))
                        action == Settings.ACTION_APPLICATION_DETAILS_SETTINGS -> Intent(action, Uri.parse("package:${activity.packageName}"))
                        action != null -> Intent(action)
                        else -> null
                    }
                    result.success(i != null && tryStart(activity, i))
                }
                "goHome" -> {
                    tryStart(activity, Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME))
                    result.success(true)
                }
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
                "getInstalledSocialApps" -> {
                    val pm = activity.packageManager
                    val known = listOf(
                        "com.instagram.android" to "Instagram",
                        "com.google.android.youtube" to "YouTube",
                        "com.snapchat.android" to "Snapchat",
                        "com.facebook.katana" to "Facebook",
                        "com.facebook.lite" to "Facebook Lite",
                        "com.zhiliaoapp.musically" to "TikTok",
                        "com.ss.android.ugc.trill" to "TikTok",
                        "com.reddit.frontpage" to "Reddit",
                        "in.mohalla.video" to "Moj",
                        "com.eterno.shortvideos" to "Josh",
                        "com.twitter.android" to "X (Twitter)",
                        "com.pinterest" to "Pinterest",
                        "in.mohalla.sharechat" to "ShareChat",
                        "video.like" to "Likee"
                    )
                    val list = ArrayList<Map<String, Any>>()
                    val prefs = RcPrefs(activity)
                    for ((pkg, defaultLabel) in known) {
                        var isInstalled = false
                        var appLabel = defaultLabel
                        try {
                            val info = pm.getApplicationInfo(pkg, 0)
                            val l = pm.getApplicationLabel(info).toString()
                            if (l.isNotEmpty()) appLabel = l
                            isInstalled = true
                        } catch (_: Exception) {}

                        val limit = prefs.int("limit_$pkg", 100)
                        val lock = prefs.bool("lock_$pkg", true)
                        list.add(mapOf(
                            "package" to pkg,
                            "label" to appLabel,
                            "installed" to isInstalled,
                            "limit" to limit,
                            "lock" to lock
                        ))
                    }
                    list.sortWith(compareByDescending<Map<String, Any>> { it["installed"] as Boolean }.thenBy { it["label"] as String })
                    result.success(list)
                }
                "setAppReelLimit" -> {
                    val pkg = str("package")
                    val limit = call.argument<Int>("limit") ?: 100
                    val lock = call.argument<Boolean>("lock") ?: true
                    val prefs = RcPrefs(activity)
                    prefs.putInt("limit_$pkg", limit)
                    prefs.putBool("lock_$pkg", lock)
                    RealCountController.active?.reload()
                    result.success(true)
                }
                "testGeminiKey" -> Thread {
                    val key = str("key")
                    try {
                        val url = java.net.URL("https://generativelanguage.googleapis.com/v1beta/models?key=$key")
                        val conn = url.openConnection() as java.net.HttpURLConnection
                        conn.requestMethod = "GET"
                        conn.connectTimeout = 8000
                        conn.readTimeout = 8000
                        val code = conn.responseCode
                        if (code in 200..299) {
                            activity.runOnUiThread { result.success(mapOf("ok" to true, "message" to "Key verified successfully!")) }
                        } else {
                            val err = try { conn.errorStream.bufferedReader().use { it.readText() } } catch (_: Exception) { "HTTP $code" }
                            var userReason = "Invalid API key ($code)"
                            if (err.contains("API_KEY_INVALID")) userReason = "The API key entered is invalid."
                            else if (err.contains("RESOURCE_EXHAUSTED")) userReason = "Quota limit reached for this API key."
                            else if (err.contains("PERMISSION_DENIED")) userReason = "Permission denied. Check if Gemini API is enabled."
                            activity.runOnUiThread { result.success(mapOf("ok" to false, "error" to userReason)) }
                        }
                    } catch (e: Exception) {
                        activity.runOnUiThread { result.success(mapOf("ok" to false, "error" to (e.message ?: "Network error. Check connection."))) }
                    }
                }.start()
                "toggleTorch" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    try {
                        val cm = activity.getSystemService(android.content.Context.CAMERA_SERVICE) as android.hardware.camera2.CameraManager
                        val id = cm.cameraIdList.firstOrNull()
                        if (id != null) cm.setTorchMode(id, on)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "setWakeWord" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    if (on && activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 42)
                        result.success(false)
                    } else {
                        RcPrefs(activity).putBool(RcPrefs.WAKE_WANTED, on)          // BootReceiver restores it
                        core.call("update_settings", JSONObject().put("android_wake_word", on).toString()) {
                            WakeWordService.enable(activity.applicationContext, on)   // started while Snapy is open
                            result.success(true)
                        }
                    }
                }
                // ---- docs/ANDROID_NEXT_PLAN.md §9 methods that live in the core runtime
                "testApiKey" -> core.call("test_api_key", str("provider"), str("key")) { result.success(jsonToMap(it)) }
                "meetingStart" -> core.call("meeting_start", call.argument<String>("title") ?: "") { result.success(jsonToMap(it)) }
                "meetingStop" -> core.call("meeting_stop") { result.success(jsonToMap(it)) }
                "meetingState" -> core.call("meeting_state") { result.success(jsonToMap(it)) }
                "profile" -> core.call("profile") { result.success(jsonToMap(it)) }
                "setProfile" -> {
                    val p = JSONObject()
                    for (k in listOf("name", "assistant_name", "ice_notes")) call.argument<String>(k)?.let { p.put(k, it) }
                    core.call("set_profile", p.toString()) { result.success(jsonToMap(it)) }
                }
                "syncNow" -> core.call("sync_kick") { result.success(true) }
                "activationModes" -> {
                    val prefs = RcPrefs(activity)
                    result.success(mapOf(
                        "wake" to WakeWordService.enabled,
                        "volume" to prefs.bool("volume_shortcut", true),
                        "power" to false,
                        "assistantRole" to isAssistantRole(activity)
                    ))
                }
                "setActivationMode" -> {
                    val mode = str("mode")
                    val on = call.argument<Boolean>("on") ?: false
                    val prefs = RcPrefs(activity)
                    when (mode) {
                        "volume" -> prefs.putBool("volume_shortcut", on)
                        "wake" -> {
                            RcPrefs(activity).putBool(RcPrefs.WAKE_WANTED, on)
                            WakeWordService.enable(activity.applicationContext, on)
                        }
                    }
                    result.success(mapOf(
                        "wake" to WakeWordService.enabled,
                        "volume" to prefs.bool("volume_shortcut", true),
                        "power" to false,
                        "assistantRole" to isAssistantRole(activity)
                    ))
                }
                "requestAssistantRole" -> {
                    try {
                        val intent = Intent(Settings.ACTION_VOICE_INPUT_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        activity.startActivity(intent)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "appIcon" -> {
                    val pkg = str("package")
                    val size = call.argument<Int>("size") ?: 96
                    Thread {
                        try {
                            val pm = activity.packageManager
                            val icon = pm.getApplicationIcon(pkg)
                            val bmp = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
                            val canvas = android.graphics.Canvas(bmp)
                            icon.setBounds(0, 0, size, size)
                            icon.draw(canvas)
                            val stream = java.io.ByteArrayOutputStream()
                            bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, stream)
                            val bytes = stream.toByteArray()
                            activity.runOnUiThread { result.success(bytes) }
                        } catch (_: Exception) {
                            activity.runOnUiThread { result.success(null) }
                        }
                    }.start()
                }
                "setAppLimit" -> {
                    val pkg = str("package")
                    val reelLimit = call.argument<Int>("reelLimit") ?: 100
                    val timeLimitMin = call.argument<Int>("timeLimitMin") ?: 0
                    val mode = call.argument<String>("mode") ?: "hard"
                    val prefs = RcPrefs(activity)
                    prefs.putInt("limit_$pkg", reelLimit)
                    prefs.putInt("time_limit_$pkg", timeLimitMin)
                    prefs.putBool("lock_$pkg", mode == "hard")
                    RealCountController.active?.reload()
                    result.success(true)
                }
                "setUnlockPin" -> {
                    val pin = str("pin")
                    RcPrefs(activity).putString("screen_unlock_pin", pin)
                    result.success(true)
                }
                "getUnlockPin" -> {
                    result.success(RcPrefs(activity).str("screen_unlock_pin", ""))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isAssistantRole(activity: Activity): Boolean {
        return try {
            val comp = Settings.Secure.getString(activity.contentResolver, "assistant") ?: return false
            comp.contains(activity.packageName)
        } catch (_: Exception) {
            false
        }
    }

    /** JSON text from the brain -> a Map for the Flutter codec (empty map on bad JSON). */
    fun jsonToMap(text: String): Map<String, Any?> = try { toPlain(JSONObject(text)) as Map<String, Any?> } catch (_: Exception) { emptyMap() }

    private fun toPlain(v: Any?): Any? = when (v) {
        is JSONObject -> HashMap<String, Any?>().also { m -> v.keys().forEach { k -> m[k] = toPlain(v.get(k)) } }
        is org.json.JSONArray -> ArrayList<Any?>().also { l -> for (i in 0 until v.length()) l.add(toPlain(v.get(i))) }
        JSONObject.NULL -> null
        else -> v
    }

    /** Some OEM settings screens don't exist or aren't exported: false instead of a crash. */
    private fun tryStart(activity: Activity, i: Intent): Boolean = try {
        activity.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true
    } catch (_: Exception) { false }

    fun isAccessibilityOn(activity: Activity): Boolean {
        if (SnapyAccessibilityService.instance != null) return true
        val enabled = Settings.Secure.getString(activity.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        val meFull = ComponentName(activity, SnapyAccessibilityService::class.java).flattenToString()
        val meShort = ComponentName(activity, SnapyAccessibilityService::class.java).flattenToShortString()
        val pkg = activity.packageName
        return enabled.split(':').any { s ->
            s.equals(meFull, ignoreCase = true) ||
            s.equals(meShort, ignoreCase = true) ||
            (s.startsWith("$pkg/", ignoreCase = true) && s.contains("AccessibilityService", ignoreCase = true))
        }
    }
}
