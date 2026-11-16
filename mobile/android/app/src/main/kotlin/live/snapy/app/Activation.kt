package live.snapy.app

import android.app.Activity
import android.app.KeyguardManager
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject

/**
 * Every way to wake Snapy goes through [Activation.trigger] (docs/ANDROID_NEXT_PLAN.md §4):
 *   "wake"     — "Hey <name>" (WakeWordService)
 *   "volume"   — Volume Up+Down held: Android's accessibility SHORTCUT with Snapy as its target.
 *                Snapy's service declares flagRequestAccessibilityButton and targets Android 11+,
 *                so (AOSP AccessibilityManagerService.performAccessibilityShortcutTargetService)
 *                the shortcut never toggles the service off: if the service is enabled and bound
 *                it calls AccessibilityButtonController's onClicked -> trigger("volume"); if it is
 *                off, the first press turns it on. Key-event filtering is NOT used (ColorOS kills
 *                services that filter keys; canRequestFilterKeyEvents stays false). [VolumeCombo]
 *                is the timing logic kept for builds/OEMs where filtering is allowed.
 *   "shortcut" — the on-screen accessibility button (same callback when no volume shortcut).
 *   "power"    — power / home long-press with Snapy as the digital assistant (AssistActivity).
 *   "ui"       — the app's mic button.
 * Each mode can be switched off in Profile (runtime settings `activation_modes`, mirrored in
 * RcPrefs act_* for this hot path). Event {"type":"activation", source}.
 */
object Activation {
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var lastAt = 0L

    fun modeOn(ctx: Context, mode: String): Boolean = when (mode) {
        "wake" -> RcPrefs(ctx).bool("act_wake", false) || RcPrefs(ctx).bool(RcPrefs.WAKE_WANTED)
        "volume", "shortcut" -> RcPrefs(ctx).bool("act_volume", true)
        "power" -> RcPrefs(ctx).bool("act_power", true)
        else -> true
    }

    /** The runtime's activation_modes -> the mirror. */
    fun mirror(ctx: Context, modes: JSONObject) {
        val p = RcPrefs(ctx)
        for (k in listOf("wake", "volume", "power")) if (modes.has(k)) p.putBool("act_$k", modes.optBoolean(k))
    }

    fun assistantRoleHeld(ctx: Context): Boolean = Build.VERSION.SDK_INT >= 29 && try {
        (ctx.getSystemService(Context.ROLE_SERVICE) as RoleManager).isRoleHeld(RoleManager.ROLE_ASSISTANT)
    } catch (_: Exception) { false }

    /**
     * ROLE_ASSISTANT is not requestable through RoleManager.createRequestRoleIntent on stock
     * Android (the role is declared requestable=false), so this opens the "Digital assistant
     * app" settings where the user picks Snapy. Returns whether Snapy holds the role now.
     */
    fun requestAssistantRole(activity: Activity): Boolean {
        if (assistantRoleHeld(activity)) return true
        val tries = listOf(
            Intent(Settings.ACTION_VOICE_INPUT_SETTINGS),
            Intent("android.settings.MANAGE_DEFAULT_APPS_SETTINGS"),
            Intent(Settings.ACTION_SETTINGS),
        )
        for (i in tries) try { activity.startActivity(i); break } catch (_: Exception) { }
        return false
    }

    fun trigger(ctx: Context, source: String) = main.post {
        val app = ctx.applicationContext
        if (!modeOn(app, source)) return@post
        val now = System.currentTimeMillis()
        if (now - lastAt < 1500) return@post                               // shortcut + combo can both fire
        lastAt = now
        val core = CoreBridge.get(app)
        core.publish(JSONObject().put("type", "activation").put("source", source))
        if (WakeWordService.isRecording) {                                 // the mic is busy recording a meeting
            WakeWordService.commandNext(app)
            return@post
        }
        val locked = (app.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked
        val greet = source != "ui"
        val begin: () -> Unit = {
            if (locked || (!AppForeground.isForeground && SnapyAccessibilityService.instance == null && !WakeWordService.running)) {
                // lock screen / no foreground context: a small activity that shows over the keyguard
                try { app.startActivity(Intent(app, ListenActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                catch (_: Exception) { VoiceController.start(app, "voice") }
            } else VoiceController.start(app, "voice")
        }
        if (!greet) { begin(); return@post }
        core.call("wake_greeting") { text ->
            val t = text.trim().trim('"')
            if (t.isEmpty() || t == "null") begin() else core.speakThen(t) { begin() }
        }
    }
}

/**
 * Volume Up + Down held [holdMs] — MIRROR of VolumeCombo in lib/core_runtime/phone_services.dart.
 * Only used when the accessibility service may filter key events (not by default, see above).
 */
class VolumeCombo(private val holdMs: Long = 2800) {
    private var upAt: Long? = null
    private var downAt: Long? = null
    private var fired = false

    val bothDown get() = upAt != null && downAt != null
    val fireAt: Long? get() = if (bothDown && !fired) maxOf(upAt!!, downAt!!) + holdMs else null

    fun onKey(up: Boolean, down: Boolean, t: Long): Boolean {
        if (down) {
            if (up) { if (upAt == null) upAt = t } else { if (downAt == null) downAt = t }
            return fired
        }
        if (up) upAt = null else downAt = null
        val consume = fired
        if (upAt == null && downAt == null) fired = false
        return consume
    }

    fun poll(t: Long): Boolean {
        val at = fireAt ?: return false
        if (t < at) return false
        fired = true
        return true
    }
}

/** Power / home long-press when Snapy is the digital assistant (intent ACTION_ASSIST). */
class AssistActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Activation.trigger(this, "power")
        finish()
        overridePendingTransition(0, 0)
    }
}

/**
 * Listening over the lock screen (setShowWhenLocked / setTurnScreenOn): the caption capsule
 * with the live words and Snapy's reply; closes 2 s after the turn ends or on a tap outside.
 * Lock-screen-safe: it never dismisses the keyguard itself (UnlockActivity does, on request).
 */
class ListenActivity : Activity() {
    private val main = Handler(Looper.getMainLooper())
    private lateinit var caption: TextView
    private val clock = CaptionClock()
    private val listener: (String) -> Unit = { batch -> main.post { onBatch(batch) } }
    private val closeCheck = object : Runnable {
        override fun run() {
            if (!clock.visible(android.os.SystemClock.uptimeMillis()) && !VoiceController.active) finish()
            else main.postDelayed(this, 500)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showOverLockScreen(this)
        val d = resources.displayMetrics
        fun dp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, d).toInt()
        caption = TextView(this).apply {
            setTextColor(CameraCapsule.TEXT)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            maxLines = 2
            setPadding(dp(14f), dp(6f), dp(14f), dp(6f))
            minHeight = dp(28f)
            gravity = Gravity.CENTER
            background = GradientDrawable().apply { cornerRadius = dp(14f).toFloat(); setColor(CameraCapsule.SURFACE); setStroke(dp(1f), CameraCapsule.OUTLINE) }
            text = Strings.t(this@ListenActivity, "chip.listening")
        }
        val root = FrameLayout(this).apply {
            setBackgroundColor(0x66000000)
            setOnClickListener { VoiceController.stop(); finish() }
            addView(caption, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply { topMargin = dp(8f) })
        }
        // Android 15+ draws edge-to-edge: keep the capsule under the status bar / cut-out
        root.setOnApplyWindowInsetsListener { v, insets ->
            val top = if (Build.VERSION.SDK_INT >= 30) insets.getInsets(android.view.WindowInsets.Type.systemBars() or android.view.WindowInsets.Type.displayCutout()).top
                      else insets.systemWindowInsetTop
            (caption.layoutParams as FrameLayout.LayoutParams).topMargin = top + dp(6f)
            caption.requestLayout()
            insets
        }
        setContentView(root)
        CoreBridge.get(this).addListener(listener)
        if (!VoiceController.active) VoiceController.start(this, "voice")
        main.postDelayed(closeCheck, 3000)
    }

    private fun onBatch(batch: String) {
        val now = android.os.SystemClock.uptimeMillis()
        val a = try { JSONArray(batch) } catch (_: Exception) { return }
        for (i in 0 until a.length()) {
            val e = a.optJSONObject(i) ?: continue
            when (e.optString("type")) {
                "voice" -> clock.voice(e.optString("state"), e.optString("text"), now)
                "speak" -> clock.speak(e.optString("text"), now)
                "speak_done" -> clock.speechDone(now)
                else -> continue
            }
            if (clock.text.isNotEmpty()) caption.text = clock.text
        }
    }

    override fun onDestroy() {
        CoreBridge.get(this).removeListener(listener)
        main.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    companion object {
        fun showOverLockScreen(a: Activity) {
            if (Build.VERSION.SDK_INT >= 27) { a.setShowWhenLocked(true); a.setTurnScreenOn(true) }
            else a.window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
            a.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }
}
