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
        // An older build stored the lock-screen PIN in plain prefs. Snapy never stores device credentials: wipe it.
        RcPrefs(activity).remove("screen_unlock_pin")
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
            // docs/ANDROID_NEXT_PLAN.md §9 (+ the legacy names on the same stores): PhoneServices.kt
            if (PhoneServices.handle(activity, core, call, result)) return@setMethodCallHandler
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
                        // short-video apps = the core catalogue (core/rules android.social_apps), never a hardcoded list
                        val socialSet = PhoneServices.catalogueShortVideoPackages(activity)
                        val list = resolves.distinctBy { it.activityInfo.packageName }.map { ri ->
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
                "getAppLabel" -> Thread {
                    val pkg = str("package")
                    if (pkg.isEmpty()) {
                        activity.runOnUiThread { result.success("") }
                        return@Thread
                    }
                    val label = try {
                        val pm = activity.packageManager
                        val ai = pm.getApplicationInfo(pkg, 0)
                        pm.getApplicationLabel(ai).toString()
                    } catch (_: Throwable) {
                        try {
                            val pm = activity.packageManager
                            val intent = pm.getLaunchIntentForPackage(pkg)
                            val ri = if (intent != null) pm.resolveActivity(intent, 0) else null
                            ri?.loadLabel(pm)?.toString()
                        } catch (_: Throwable) {
                            null
                        }
                    } ?: run {
                        val lastPart = pkg.substringAfterLast('.')
                        if (lastPart.isNotEmpty()) {
                            lastPart.replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() }
                        } else pkg
                    }
                    activity.runOnUiThread {
                        if (!activity.isFinishing && !activity.isDestroyed) {
                            result.success(label)
                        }
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
                        val labelsObj = JSONObject()
                        t.labels.forEach { (k, v) -> labelsObj.put(k, v) }
                        val out = JSONObject()
                            .put("screen_ms", t.totalMs)
                            .put("per_app_ms", perApp)
                            .put("opens", opensObj)
                            .put("labels", labelsObj)
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
                                val empty = JSONObject().put("screen_ms", 0L).put("per_app_ms", JSONObject()).put("opens", JSONObject()).put("labels", JSONObject()).put("realcount", JSONObject())
                                result.success(empty.toString())
                            }
                        }
                    }
                }.start()
                "getWeeklyScreenTime" -> Thread {
                    try {
                        val offset = call.argument<Int>("offset") ?: 0
                        val list = usage.week(offset)
                        val mins = list.map { (it / 60000L).toInt() }
                        activity.runOnUiThread {
                            if (!activity.isFinishing && !activity.isDestroyed) {
                                result.success(mins)
                            }
                        }
                    } catch (t: Throwable) {
                        android.util.Log.e("SnapyChannels", "Error calculating weekly usage", t)
                        activity.runOnUiThread {
                            if (!activity.isFinishing && !activity.isDestroyed) {
                                result.success(List(7) { 0 })
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
                // getInstalledSocialApps / setAppReelLimit / testGeminiKey / testApiKey / meeting* /
                // setProfile / activationModes / setActivationMode / requestAssistantRole / appIcon:
                // PhoneServices.handle (above) answers them on the shared stores (ReelLimits, the
                // runtime's test_api_key — the key never goes into a URL here).
                "toggleTorch" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    try {
                        val cm = activity.getSystemService(android.content.Context.CAMERA_SERVICE) as android.hardware.camera2.CameraManager
                        val id = cm.cameraIdList.firstOrNull {
                            cm.getCameraCharacteristics(it).get(android.hardware.camera2.CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
                        }
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
                        // the same path as Profile's switch: the runtime's activation_modes (also sets
                        // android_wake_word) -> the act_wake mirror Activation.trigger("wake") checks
                        core.call("set_activation_mode", "wake", "$on") { r ->
                            try { Activation.mirror(activity.applicationContext, JSONObject(r)) } catch (_: Exception) { }
                            WakeWordService.enable(activity.applicationContext, on)   // started while Snapy is open
                            result.success(true)
                        }
                    }
                }
                "profile" -> core.call("profile") { result.success(jsonToMap(it)) }
                "syncNow" -> core.call("sync_kick") { result.success(true) }
                // per-app limits: the reel part goes to the one reel-limit store (ReelLimits + the
                // runtime's reel_limits, soft unless "hard" is asked); the daily time limit stays in RcPrefs
                "setAppLimit" -> {
                    val pkg = str("package")
                    if (pkg.isEmpty()) { result.success(false); return@setMethodCallHandler }
                    val reelLimit = (call.argument<Int>("reelLimit") ?: 0).coerceAtLeast(0)
                    val timeLimitMin = (call.argument<Int>("timeLimitMin") ?: 0).coerceAtLeast(0)
                    val mode = if (call.argument<String>("mode") == "hard") "hard" else "soft"
                    RcPrefs(activity).putInt("time_limit_$pkg", timeLimitMin)
                    ReelLimits.set(activity, pkg, reelLimit, mode)
                    core.call("set_reel_limit", pkg, "$reelLimit", mode) { }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
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
