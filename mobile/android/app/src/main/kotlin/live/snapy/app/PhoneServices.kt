package live.snapy.app

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.util.LruCache
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The docs/ANDROID_NEXT_PLAN.md §9 methods on "snapy/core" (called first by SnapyChannels).
 * Names, args and return shapes exactly as the contract lists them (lib/core/next_api.dart):
 *   shortVideoApps · appIcon · reelLimits / setReelLimit · activationModes / setActivationMode ·
 *   requestAssistantRole · testApiKey · meetingStart / meetingStop / meetingState ·
 *   vaultList / vaultExport / vaultClear · captureVideo · sosStart / sosStop · profile / setProfile
 * plus: capturePhoto, vaultGhost / setVaultGhost, openUrl, and the legacy names the UI falls
 * back to (getInstalledSocialApps, setAppReelLimit, testGeminiKey) on the same stores.
 */
object PhoneServices {
    private val icons = object : LruCache<String, ByteArray>(2 * 1024 * 1024) {
        override fun sizeOf(key: String, value: ByteArray) = value.size
    }

    private fun post(result: MethodChannel.Result, v: Any?) = CoreBridge.mainHandler.post { result.success(v) }

    /** true = handled. */
    fun handle(activity: Activity, core: CoreBridge, call: MethodCall, result: MethodChannel.Result): Boolean {
        fun str(k: String) = call.argument<String>(k) ?: ""
        val ctx = activity.applicationContext
        when (call.method) {
            // ---------------------------------------------------------------- short-video apps
            "shortVideoApps" -> Thread { post(result, shortVideoApps(activity)) }.start()
            "appIcon" -> {
                val pkg = str("package"); val size = (call.argument<Int>("size") ?: 96).coerceIn(24, 256)
                Thread { post(result, appIcon(activity, pkg, size)) }.start()
            }
            "reelLimits" -> Thread { post(result, reelLimits(activity)) }.start()
            "setReelLimit" -> {
                val pkg = str("package")
                val limit = (call.argument<Int>("limit") ?: 0).coerceAtLeast(0)
                val mode = if (str("mode") == "hard") "hard" else "soft"
                if (pkg.isEmpty()) { result.success(false); return true }
                ReelLimits.set(ctx, pkg, limit, mode)
                core.call("set_reel_limit", pkg, "$limit", mode) { }
                Thread { post(result, reelLimits(activity)) }.start()
            }
            "getInstalledSocialApps" -> Thread {
                val list = shortVideoApps(activity).map { a ->
                    val c = ReelLimits.get(ctx, a["package"] as String)
                    a + mapOf("limit" to c.limit, "lock" to c.hard, "mode" to c.mode)
                }
                post(result, list)
            }.start()
            "setAppReelLimit" -> {
                val pkg = str("package")
                val limit = (call.argument<Int>("limit") ?: 0).coerceAtLeast(0)
                val mode = if (call.argument<Boolean>("lock") == true) "hard" else "soft"
                ReelLimits.set(ctx, pkg, limit, mode)
                core.call("set_reel_limit", pkg, "$limit", mode) { }
                result.success(true)
            }
            // ---------------------------------------------------------------- activation
            "activationModes" -> core.call("activation_modes") { r -> result.success(activationMap(activity, r)) }
            "setActivationMode" -> {
                val mode = str("mode"); val on = call.argument<Boolean>("on") ?: false
                if (mode == "wake") {
                    if (on && activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 42)
                        core.call("activation_modes") { r -> result.success(activationMap(activity, r)) }
                        return true
                    }
                    RcPrefs(ctx).putBool(RcPrefs.WAKE_WANTED, on)            // BootReceiver restores it
                }
                core.call("set_activation_mode", mode, "$on") { r ->
                    try { Activation.mirror(ctx, JSONObject(r)) } catch (_: Exception) { }
                    if (mode == "wake") WakeWordService.enable(ctx, on)      // started while Snapy is visible
                    result.success(activationMap(activity, r))
                }
            }
            "requestAssistantRole" -> result.success(Activation.requestAssistantRole(activity))
            // ---------------------------------------------------------------- AI key (§1 copy)
            "testApiKey" -> core.call("test_api_key", str("provider").ifEmpty { "gemini" }, str("key")) { result.success(SnapyChannels.jsonToMap(it)) }
            "testGeminiKey" -> core.call("test_api_key", "gemini", str("key")) { r ->
                val m = SnapyChannels.jsonToMap(r)
                result.success(m + mapOf("error" to (if (m["ok"] == true) null else m["message"])))
            }
            // ---------------------------------------------------------------- meetings (§5)
            "meetingStart" -> {
                // the mic service may only start now, while Snapy is on screen
                if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                    // no mic = nothing to record or transcribe: ask, and let the user tap Start again
                    activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 42)
                    core.call("meeting_state") { result.success(SnapyChannels.jsonToMap(it) + mapOf("error" to "need_mic")) }
                    return true
                }
                core.call("meeting_start", call.argument<String>("title") ?: "") { result.success(SnapyChannels.jsonToMap(it)) }
            }
            "meetingStop" -> core.call("meeting_stop") { result.success(SnapyChannels.jsonToMap(it)) }
            "meetingState" -> core.call("meeting_state") { result.success(SnapyChannels.jsonToMap(it)) }
            // ---------------------------------------------------------------- vault (§8 Ghost mode)
            "vaultList" -> gated(activity) { ok ->
                if (!ok) { result.success(emptyList<Any>()); return@gated }
                core.call("vault_list", str("kind").ifEmpty { "all" }) { r -> Thread { post(result, openItems(r)) }.start() }
            }
            "vaultExport" -> gated(activity) { ok ->
                if (!ok) { result.success(null); return@gated }
                val kind = str("kind").ifEmpty { "all" }
                core.call("vault_list", kind) { r -> Thread { post(result, export(activity, kind, openItems(r))) }.start() }
            }
            "vaultClear" -> gated(activity) { ok ->
                if (!ok) { result.success(false); return@gated }
                core.call("vault_clear", str("kind").ifEmpty { "all" }) { r -> result.success(SnapyChannels.jsonToMap(r)["ok"] == true) }
            }
            "vaultGhost" -> result.success(mapOf("on" to GhostVault.enabled(ctx), "secure" to deviceSecure(activity)))
            "setVaultGhost" -> {
                val on = call.argument<Boolean>("on") ?: false
                // Ghost mode needs a screen lock (the Keystore key is bound to it); say so instead of a failing prompt
                if (on && !deviceSecure(activity)) { result.success(mapOf("on" to GhostVault.enabled(ctx), "error" to "no_secure_lock")); return true }
                GhostVault.authenticate(activity) { ok ->
                    if (!ok) { result.success(mapOf("on" to GhostVault.enabled(ctx), "error" to "auth")); return@authenticate }
                    Thread { val err = GhostVault.setEnabled(ctx, on); post(result, mapOf("on" to GhostVault.enabled(ctx), "error" to err)) }.start()
                }
            }
            // ---------------------------------------------------------------- device actions (§7)
            "captureVideo" -> { core.call("capture_started") { }; result.success(CaptureActivity.start(activity, "video", if (str("camera") == "front") "front" else "back")) }
            "capturePhoto" -> { core.call("capture_started") { }; result.success(CaptureActivity.start(activity, "photo", if (str("camera") == "front") "front" else "back")) }
            "sosStart" -> core.call("sos_info") { r ->
                val number = try { JSONObject(r).optString("number", "112") } catch (_: Exception) { "112" }
                result.success(SosActivity.start(activity, number))
            }
            "sosStop" -> result.success(SosActivity.stop())
            "openUrl" -> result.success(try {
                activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(str("url"))).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true
            } catch (_: Exception) { false })
            // ---------------------------------------------------------------- diagnostics (SnapyApp.kt)
            // file reads off the main thread; the result is posted back
            "a11yHealth" -> Thread { post(result, try { A11yHealth.state(ctx) } catch (_: Throwable) { mapOf("state" to "off") }) }.start()
            "crashReports" -> Thread { post(result, CrashLog.reports(ctx).map { (f, t) -> mapOf("file" to f, "text" to t) }) }.start()
            "clearCrashReports" -> Thread { CrashLog.clear(ctx); post(result, true) }.start()
            // ---------------------------------------------------------------- profile (+ ice_notes, avatar)
            "setProfile" -> {
                val p = JSONObject()
                for (k in listOf("name", "assistant_name", "ice_notes", "avatar")) call.argument<String>(k)?.let { p.put(k, it) }
                core.call("set_profile", p.toString()) { result.success(SnapyChannels.jsonToMap(it)) }
            }
            else -> return false
        }
        return true
    }

    // ------------------------------------------------------------------ helpers
    private fun catalogue(ctx: android.content.Context): List<JSONObject> {
        val a = CoreConfig.value(ctx, "android.social_apps") as? JSONArray ?: return emptyList()
        return (0 until a.length()).mapNotNull { a.optJSONObject(it) }
    }

    /** Packages the catalogue marks as short-video apps (short_video set), installed or not. */
    fun catalogueShortVideoPackages(ctx: android.content.Context): Set<String> =
        catalogue(ctx).filter { !it.isNull("short_video") }.map { it.optString("package") }.filter { it.isNotEmpty() }.toSet()

    /** installed ∩ the catalogue's short-video apps (core rules android.social_apps). */
    fun shortVideoApps(activity: Activity): List<Map<String, Any>> {
        val pm = activity.packageManager
        val out = ArrayList<Map<String, Any>>()
        val seen = HashSet<String>()
        for (app in catalogue(activity)) {
            if (app.isNull("short_video")) continue
            val pkg = app.optString("package")
            if (pkg.isEmpty() || !seen.add(pkg) || pm.getLaunchIntentForPackage(pkg) == null) continue
            val label = try { pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString() } catch (_: Exception) { app.optString("label", pkg) }
            out.add(mapOf("package" to pkg, "label" to label, "kind" to app.optString("short_video"), "installed" to true))
        }
        return out.sortedBy { (it["label"] as String).lowercase() }
    }

    fun appIcon(activity: Activity, pkg: String, size: Int): ByteArray? {
        val key = "$pkg@$size"
        icons.get(key)?.let { return it }
        return try {
            val d = activity.packageManager.getApplicationIcon(pkg)
            val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val c = Canvas(bmp)
            d.setBounds(0, 0, size, size); d.draw(c)
            val bytes = ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
            bmp.recycle()
            icons.put(key, bytes)
            bytes
        } catch (_: Exception) { null }
    }

    /** {package: {limit, mode, used, state}} for every configured or installed short-video app. */
    fun reelLimits(activity: Activity): Map<String, Map<String, Any?>> {
        val pkgs = LinkedHashSet<String>()
        shortVideoApps(activity).forEach { pkgs.add(it["package"] as String) }
        pkgs.addAll(ReelLimits.all(activity).keys)
        return pkgs.associateWith { SnapyChannels.jsonToMap(ReelLockController.rowFor(activity, it).toString()) }
    }

    private fun activationMap(activity: Activity, json: String): Map<String, Any?> {
        val m = SnapyChannels.jsonToMap(json).toMutableMap()
        if (m.isEmpty()) {                                  // brain not up yet: the mirror
            for (k in listOf("wake", "volume", "power")) m[k] = Activation.modeOn(activity, k)
        }
        m["wake"] = m["wake"] == true
        m["assistantRole"] = Activation.assistantRoleHeld(activity)
        m["shortcut"] = SnapyChannels.isAccessibilityOn(activity)          // volume shortcut needs the Real Count service
        shortcutTarget(activity)?.let { m["shortcutTarget"] = it }
        return m
    }

    /**
     * Is Snapy the volume-key accessibility shortcut's target? Settings.Secure
     * "accessibility_shortcut_target_service" (colon-separated components). Not a public
     * constant: some Android versions / OEMs refuse to read it -> null (the UI then just shows
     * the setup steps).
     */
    private fun shortcutTarget(activity: Activity): Boolean? = try {
        val v = android.provider.Settings.Secure.getString(activity.contentResolver, "accessibility_shortcut_target_service")
        if (v == null) null else v.split(':').any { it.startsWith(activity.packageName + "/") }
    } catch (_: Exception) { null }

    private fun deviceSecure(activity: Activity): Boolean =
        (activity.getSystemService(android.content.Context.KEYGUARD_SERVICE) as android.app.KeyguardManager).isDeviceSecure

    /** Ghost mode: the biometric prompt first (skipped inside the auth window). */
    private fun gated(activity: Activity, then: (Boolean) -> Unit) {
        if (!GhostVault.enabled(activity)) { then(true); return }
        GhostVault.authenticate(activity, then)
    }

    /** Runtime vault_list items; sealed files decrypted (needs the fresh auth). */
    private fun openItems(json: String): List<Map<String, Any?>> {
        val a = try { JSONArray(json) } catch (_: Exception) { JSONArray() }
        val out = ArrayList<Map<String, Any?>>()
        for (i in 0 until a.length()) {
            val o = a.optJSONObject(i) ?: continue
            if (o.optBoolean("encrypted")) {
                val md = GhostVault.openText(File(o.optString("path")))
                o.put("markdown", md ?: "").put("locked", md == null)
                if (md != null) Regex("^# (.+)$", RegexOption.MULTILINE).find(md)?.let { o.put("title", it.groupValues[1]) }
            }
            out.add(SnapyChannels.jsonToMap(o.toString()))
        }
        return out
    }

    /** Markdown + JSON export in files/snapy/exports (app-private; the UI shares it). Returns the .md path. */
    private fun export(activity: Activity, kind: String, items: List<Map<String, Any?>>): String? = try {
        val dir = File(activity.filesDir, "snapy/exports").apply { mkdirs() }
        val stamp = SimpleDateFormat("yyyy-MM-dd_HHmm", Locale.US).format(Date())
        val md = StringBuilder("# Snapy vault — $kind\n\n")
        for (it in items) {
            md.append("## ").append((it["title"] ?: "").toString()).append('\n')
            (it["date"] as? String)?.let { d -> md.append("_").append(d).append("_\n") }
            md.append('\n').append((it["markdown"] ?: "").toString()).append("\n\n---\n\n")
        }
        val f = File(dir, "snapy-vault-$kind-$stamp.md")
        f.writeText(md.toString())
        File(dir, "snapy-vault-$kind-$stamp.json").writeText(JSONArray(items.map { JSONObject(it) }).toString(2))
        f.absolutePath
    } catch (_: Exception) { null }
}
