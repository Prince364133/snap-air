@file:Suppress("DEPRECATION")

package live.snapy.app

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.TypedValue
import android.view.Gravity
import android.view.WindowInsets
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject
import java.lang.ref.WeakReference

/** MIRROR of SosMachine in lib/core_runtime/phone_services.dart (test/phone_services_test.dart). */
class SosMachine(var number: String = "112") {
    var state = IDLE; private set
    var startedAt = 0L; private set

    fun start(now: Long): Boolean { if (state != IDLE) return false; state = ACTIVE; startedAt = now; return true }
    fun askCall(): Boolean { if (state != ACTIVE) return false; state = CONFIRMING; return true }
    fun confirmCall(): String? { if (state != CONFIRMING) return null; state = ACTIVE; return number }
    fun cancelCall() { if (state == CONFIRMING) state = ACTIVE }
    fun stop(): Boolean { if (state == IDLE) return false; state = IDLE; return true }
    val alarming get() = state != IDLE

    companion object {
        const val IDLE = "idle"; const val ACTIVE = "active"; const val CONFIRMING = "confirming"
        private val sos: BooleanArray = run {
            val out = ArrayList<Boolean>()
            fun mark(u: Int) { repeat(u) { out.add(true) }; out.add(false) }
            for (letter in listOf(listOf(1, 1, 1), listOf(3, 3, 3), listOf(1, 1, 1))) { letter.forEach { mark(it) }; out.add(false); out.add(false) }
            repeat(4) { out.add(false) }
            out.toBooleanArray()
        }
        /** Morse "SOS" strobe, [unitMs] per dot. */
        fun torchOn(elapsedMs: Long, unitMs: Long = 200): Boolean = sos[((elapsedMs / unitMs) % sos.size).toInt()]
    }
}

/**
 * Offline SOS (docs/ANDROID_NEXT_PLAN.md §7): torch strobe (Morse SOS), a loud alarm tone on
 * STREAM_ALARM, and the ICE card (name + medical notes from Profile, stored on the phone) over
 * the lock screen. "Call <number>" asks first, then opens the dialer (ACTION_DIAL — the user
 * presses call; Snapy never calls on its own). The number comes from core config
 * android.emergency_number (default 112, the runtime's sos_info).
 */
class SosActivity : Activity() {
    private val main = Handler(Looper.getMainLooper())
    private val machine = SosMachine()
    private var player: MediaPlayer? = null
    private var torchId: String? = null
    private var torchState = false
    private var savedAlarmVolume = -1
    private lateinit var titleView: TextView
    private lateinit var ice: TextView
    private lateinit var callBtn: TextView
    private lateinit var stopBtn: TextView
    private var info = JSONObject()

    private val strobe = object : Runnable {
        override fun run() {
            if (!machine.alarming) return
            val on = SosMachine.torchOn(SystemClock.elapsedRealtime() - machine.startedAt)
            if (on != torchState) setTorch(on)
            main.postDelayed(this, 50)
        }
    }

    private fun dp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        current = WeakReference(this)
        ListenActivity.showOverLockScreen(this)
        machine.number = intent.getStringExtra("number")?.takeIf { it.isNotBlank() } ?: "112"
        buildUi()
        CoreBridge.get(this).call("sos_info") { r ->
            try { info = JSONObject(r) } catch (_: Exception) { }
            info.optString("number").takeIf { it.isNotBlank() }?.let { machine.number = it }
            render()
        }
        CoreBridge.get(this).call("sos_state", "true") { }
        if (machine.start(SystemClock.elapsedRealtime())) { startAlarm(); findTorch(); main.post(strobe) }
    }

    /** The runtime's sos_info copy, else core/i18n (Strings), else English. */
    private fun label(k: String, key: String, fallback: String): String = info.optString(k).ifBlank {
        Strings.t(this, key, mapOf("number" to machine.number)).let { if (it == key) fallback else it }
    }

    private fun buildUi() {
        fun big(text: String, bg: Int, click: () -> Unit) = TextView(this).apply {
            this.text = text
            setTextColor(0xFFFFFFFF.toInt()); setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            gravity = Gravity.CENTER
            setPadding(dp(16f), dp(18f), dp(16f), dp(18f))
            background = GradientDrawable().apply { cornerRadius = dp(18f).toFloat(); setColor(bg) }
            setOnClickListener { click() }
        }
        titleView = TextView(this).apply {
            text = label("title", "sos.title", "SOS"); setTextColor(0xFFFFFFFF.toInt()); setTextSize(TypedValue.COMPLEX_UNIT_SP, 44f)
            typeface = Typeface.DEFAULT_BOLD; gravity = Gravity.CENTER
        }
        ice = TextView(this).apply {
            setTextColor(0xFFFFFFFF.toInt()); setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            setPadding(dp(16f), dp(16f), dp(16f), dp(16f))
            background = GradientDrawable().apply { cornerRadius = dp(16f).toFloat(); setColor(0x33000000) }
        }
        callBtn = big(label("call_label", "sos.call", "Call ${machine.number}"), 0xFF1F1F1F.toInt()) { askCall() }
        stopBtn = big(label("stop_label", "sos.stop", "I'm safe — stop"), 0x55000000) { stopSos() }
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20f), dp(24f), dp(20f), dp(24f))
            addView(titleView)
            addView(ice, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(16f) })
            addView(callBtn, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(24f) })
            addView(stopBtn, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(12f) })
        }
        val root = ScrollView(this).apply { setBackgroundColor(CameraCapsule.RECORDING); addView(col) }
        root.setOnApplyWindowInsetsListener { _, insets ->                 // Android 15+ edge-to-edge
            if (Build.VERSION.SDK_INT >= 30) {
                val i = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                col.setPadding(dp(20f), i.top + dp(24f), dp(20f), i.bottom + dp(24f))
            }
            insets
        }
        setContentView(root)
        render()
    }

    private fun render() {
        val name = info.optString("name")
        val notes = info.optString("ice_notes")
        ice.text = buildString {
            append(label("ice_title", "sos.ice_title", "Medical / ICE notes"))
            if (name.isNotBlank()) append("\n").append(name)
            append("\n\n").append(notes.ifBlank { "—" })
        }
        titleView.text = label("title", "sos.title", "SOS")
        callBtn.text = label("call_label", "sos.call", "Call ${machine.number}")
        stopBtn.text = label("stop_label", "sos.stop", "I'm safe — stop")
    }

    fun askCall() {
        if (!machine.askCall()) return
        AlertDialog.Builder(this)
            .setMessage(label("confirm", "sos.confirm", "Call ${machine.number} now?"))
            .setPositiveButton(android.R.string.ok) { _, _ -> machine.confirmCall()?.let { dial(it) } }
            .setNegativeButton(android.R.string.cancel) { _, _ -> machine.cancelCall() }
            .setOnCancelListener { machine.cancelCall() }
            .show()
    }

    private fun dial(number: String) {
        try { startActivity(Intent(Intent.ACTION_DIAL, Uri.parse("tel:" + Uri.encode(number))).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } catch (_: Exception) { }
    }

    private fun startAlarm() {
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            savedAlarmVolume = am.getStreamVolume(AudioManager.STREAM_ALARM)
            am.setStreamVolume(AudioManager.STREAM_ALARM, am.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0)
        } catch (_: Exception) { }
        try {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                ?: throw IllegalStateException("no alarm or ringtone sound on this phone")   // strobe + screen still work
            player = MediaPlayer().apply {
                setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                setDataSource(this@SosActivity, uri)
                isLooping = true
                prepare(); start()
            }
        } catch (_: Exception) { player = null }
    }

    private fun findTorch() {
        try {
            val cm = getSystemService(Context.CAMERA_SERVICE) as CameraManager
            torchId = cm.cameraIdList.firstOrNull { cm.getCameraCharacteristics(it).get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true }
        } catch (_: Exception) { torchId = null }
    }

    private fun setTorch(on: Boolean) {
        val id = torchId ?: return
        try { (getSystemService(Context.CAMERA_SERVICE) as CameraManager).setTorchMode(id, on); torchState = on } catch (_: Exception) { torchId = null }
    }

    fun stopSos() { machine.stop(); finish() }

    private fun release() {
        main.removeCallbacksAndMessages(null)
        if (torchState) setTorch(false)
        try { player?.stop() } catch (_: Exception) { }
        player?.release(); player = null
        if (savedAlarmVolume >= 0) try {
            (getSystemService(Context.AUDIO_SERVICE) as AudioManager).setStreamVolume(AudioManager.STREAM_ALARM, savedAlarmVolume, 0)
        } catch (_: Exception) { }
        savedAlarmVolume = -1
    }

    override fun onDestroy() {
        machine.stop()
        release()
        if (current?.get() === this) current = null
        CoreBridge.get(this).call("sos_state", "false") { }
        super.onDestroy()
    }

    companion object {
        @Volatile private var current: WeakReference<SosActivity>? = null
        val isActive get() = current?.get() != null

        fun start(ctx: Context, number: String): Boolean = try {
            ctx.startActivity(Intent(ctx, SosActivity::class.java).putExtra("number", number)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)); true
        } catch (_: Exception) { false }

        fun stop(): Boolean { val a = current?.get() ?: return false; a.runOnUiThread { a.stopSos() }; return true }

        /** Voice "yes, call emergency": the dialer with the number (the user presses call). */
        fun dial(ctx: Context, number: String) {
            try { ctx.startActivity(Intent(Intent.ACTION_DIAL, Uri.parse("tel:" + Uri.encode(number))).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } catch (_: Exception) { }
        }
    }
}
