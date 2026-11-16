@file:Suppress("DEPRECATION")

package live.snapy.app

import android.Manifest
import android.annotation.SuppressLint
import android.app.KeyguardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.MediaStoreOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.lang.ref.WeakReference
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Snapy's camera screen (docs/ANDROID_NEXT_PLAN.md §7): "take a video with the front camera",
 * "take a photo", "stop recording". Android blocks background camera use, so the camera only
 * runs while this screen is visible (no camera foreground service); it shows over the lock
 * screen (setShowWhenLocked) unless the user requires an unlock (RcPrefs capture_requires_unlock,
 * then KeyguardManager.requestDismissKeyguard first). Saves to the gallery (MediaStore,
 * Movies/Snapy and Pictures/Snapy). CAMERA (and RECORD_AUDIO for sound) are asked here, in context.
 */
class CaptureActivity : ComponentActivity() {
    private val main = Handler(Looper.getMainLooper())
    private lateinit var preview: PreviewView
    private lateinit var status: TextView
    private lateinit var shutter: TextView
    private var provider: ProcessCameraProvider? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var imageCapture: ImageCapture? = null
    private var recording: Recording? = null
    private var mode = "video"
    private var front = false
    private var auto = true
    private var startedAt = 0L
    private val timer = object : Runnable {
        override fun run() {
            if (recording == null) return
            val s = (SystemClock.elapsedRealtime() - startedAt) / 1000
            status.text = String.format(Locale.US, "● %02d:%02d", s / 60, s % 60)
            main.postDelayed(this, 500)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        current = WeakReference(this)
        mode = intent.getStringExtra(EXTRA_MODE) ?: "video"
        front = intent.getStringExtra(EXTRA_CAMERA) == "front"
        auto = intent.getBooleanExtra(EXTRA_AUTO, true)
        ListenActivity.showOverLockScreen(this)
        buildUi()
        val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (RcPrefs(this).bool("capture_requires_unlock", false) && km.isKeyguardLocked) {
            km.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
                override fun onDismissSucceeded() = askPermissionsThenStart()
                override fun onDismissCancelled() = finish()
                override fun onDismissError() = finish()
            })
        } else askPermissionsThenStart()
    }

    private fun dp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics).toInt()

    private fun button(label: String, onClick: () -> Unit) = TextView(this).apply {
        text = label
        setTextColor(CameraCapsule.TEXT)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        gravity = Gravity.CENTER
        setPadding(dp(16f), dp(10f), dp(16f), dp(10f))
        background = GradientDrawable().apply { cornerRadius = dp(22f).toFloat(); setColor(CameraCapsule.SURFACE); setStroke(dp(1f), CameraCapsule.OUTLINE) }
        setOnClickListener { onClick() }
    }

    private fun buildUi() {
        preview = PreviewView(this).apply { implementationMode = PreviewView.ImplementationMode.COMPATIBLE }
        status = TextView(this).apply {
            setTextColor(CameraCapsule.TEXT); setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
            setPadding(dp(12f), dp(5f), dp(12f), dp(5f))
            background = GradientDrawable().apply { cornerRadius = dp(14f).toFloat(); setColor(CameraCapsule.SURFACE) }
        }
        shutter = button(if (mode == "video") t("capture.stop", "Stop") else t("capture.photo", "Take photo")) { onShutter() }
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            addView(button(t("capture.flip", "Flip")) { flip() })
            addView(View(this@CaptureActivity), LinearLayout.LayoutParams(dp(12f), 1))
            addView(shutter)
            addView(View(this@CaptureActivity), LinearLayout.LayoutParams(dp(12f), 1))
            addView(button(t("capture.close", "Close")) { finish() })
        }
        val root = FrameLayout(this).apply {
            setBackgroundColor(0xFF000000.toInt())
            addView(preview, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
            addView(status, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.CENTER_HORIZONTAL))
            addView(bar, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
        }
        // Android 15+ is edge-to-edge: keep the controls clear of the bars and the cut-out
        root.setOnApplyWindowInsetsListener { _, insets ->
            val top: Int; val bottom: Int
            if (Build.VERSION.SDK_INT >= 30) {
                val i = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                top = i.top; bottom = i.bottom
            } else { top = insets.systemWindowInsetTop; bottom = insets.systemWindowInsetBottom }
            (status.layoutParams as FrameLayout.LayoutParams).topMargin = top + dp(8f)
            (bar.layoutParams as FrameLayout.LayoutParams).bottomMargin = bottom + dp(20f)
            status.requestLayout(); bar.requestLayout()
            insets
        }
        setContentView(root)
    }

    private fun t(key: String, fallback: String) = Strings.t(this, key).let { if (it == key) fallback else it }

    private fun granted(p: String) = ContextCompat.checkSelfPermission(this, p) == PackageManager.PERMISSION_GRANTED

    private fun askPermissionsThenStart() {
        val need = buildList {
            if (!granted(Manifest.permission.CAMERA)) add(Manifest.permission.CAMERA)
            if (mode == "video" && !granted(Manifest.permission.RECORD_AUDIO)) add(Manifest.permission.RECORD_AUDIO)
        }
        if (need.isEmpty()) bind() else requestPermissions(need.toTypedArray(), REQ)
    }

    @Deprecated("framework callback")
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ) return
        if (granted(Manifest.permission.CAMERA)) bind()
        else { Toast.makeText(this, t("capture.need_camera", "Snapy needs the camera permission for this."), Toast.LENGTH_LONG).show(); finish() }
    }

    private fun bind() {
        val f = ProcessCameraProvider.getInstance(this)
        f.addListener({
            try {
                val p = f.get(); provider = p
                val pv = Preview.Builder().build().also { it.setSurfaceProvider(preview.surfaceProvider) }
                val selector = if (front) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
                p.unbindAll()
                if (mode == "video") {
                    val rec = Recorder.Builder()
                        .setQualitySelector(QualitySelector.from(Quality.HD, FallbackStrategy.lowerQualityOrHigherThan(Quality.SD)))
                        .build()
                    val vc = VideoCapture.withOutput(rec)
                    videoCapture = vc
                    p.bindToLifecycle(this, selector, pv, vc)
                    if (auto && recording == null) main.postDelayed({ startRecording() }, 400)
                } else {
                    val ic = ImageCapture.Builder().setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY).build()
                    imageCapture = ic
                    p.bindToLifecycle(this, selector, pv, ic)
                    if (auto) main.postDelayed({ takePhoto() }, 900)
                }
            } catch (e: Exception) {
                Toast.makeText(this, t("capture.no_camera", "The camera isn't available right now."), Toast.LENGTH_LONG).show()
                finish()
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun name() = "Snapy_" + SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())

    @SuppressLint("MissingPermission")     // RECORD_AUDIO is checked right here
    private fun startRecording() {
        val vc = videoCapture ?: return
        if (recording != null) return
        val cv = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name())
            put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4")
            if (Build.VERSION.SDK_INT >= 29) put(MediaStore.MediaColumns.RELATIVE_PATH, "Movies/Snapy")
        }
        val opts = MediaStoreOutputOptions.Builder(contentResolver, MediaStore.Video.Media.EXTERNAL_CONTENT_URI).setContentValues(cv).build()
        val pending = vc.output.prepareRecording(this, opts)
        if (granted(Manifest.permission.RECORD_AUDIO)) pending.withAudioEnabled()
        recording = pending.start(ContextCompat.getMainExecutor(this)) { ev ->
            if (ev is VideoRecordEvent.Finalize) {
                val ok = !ev.hasError() || ev.error == VideoRecordEvent.Finalize.ERROR_SOURCE_INACTIVE
                CoreBridge.get(this).publish(JSONObject().put("type", "capture").put("state", if (ok) "saved" else "error").put("mode", "video"))
                Toast.makeText(applicationContext, if (ok) t("capture.saved", "Saved to your gallery") else t("capture.failed", "Couldn't save the video"), Toast.LENGTH_SHORT).show()
                recording = null
                if (stopAndClose) finish()
            }
        }
        startedAt = SystemClock.elapsedRealtime()
        shutter.text = t("capture.stop", "Stop")
        main.post(timer)
        CoreBridge.get(this).publish(JSONObject().put("type", "capture").put("state", "recording").put("camera", if (front) "front" else "back"))
    }

    private var stopAndClose = false

    fun stopRecording(close: Boolean = true) {
        val r = recording
        if (r == null) { if (close) finish(); return }
        stopAndClose = close
        main.removeCallbacks(timer)
        r.stop()
    }

    private fun takePhoto() {
        val ic = imageCapture ?: return
        val cv = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name())
            put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
            if (Build.VERSION.SDK_INT >= 29) put(MediaStore.MediaColumns.RELATIVE_PATH, "Pictures/Snapy")
        }
        val out = ImageCapture.OutputFileOptions.Builder(contentResolver, MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cv).build()
        ic.takePicture(out, ContextCompat.getMainExecutor(this), object : ImageCapture.OnImageSavedCallback {
            override fun onImageSaved(r: ImageCapture.OutputFileResults) {
                CoreBridge.get(this@CaptureActivity).publish(JSONObject().put("type", "capture").put("state", "saved").put("mode", "photo"))
                Toast.makeText(applicationContext, t("capture.saved", "Saved to your gallery"), Toast.LENGTH_SHORT).show()
                if (auto) main.postDelayed({ finish() }, 1200)
            }
            override fun onError(e: ImageCaptureException) {
                Toast.makeText(applicationContext, t("capture.failed_photo", "Couldn't take the photo"), Toast.LENGTH_SHORT).show()
            }
        })
    }

    private fun onShutter() {
        if (mode == "video") { if (recording != null) stopRecording(close = true) else startRecording() } else takePhoto()
    }

    private fun flip() {
        if (recording != null) return                 // CameraX can't switch cameras mid-recording
        front = !front
        bind()
    }

    override fun onStop() {
        // no background camera: leaving the screen ends the recording (it is still saved)
        if (recording != null) stopRecording(close = false)
        super.onStop()
        if (!isChangingConfigurations) finish()
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        recording?.stop(); recording = null
        provider?.unbindAll()
        if (current?.get() === this) current = null
        CoreBridge.get(this).call("capture_ended") { }
        super.onDestroy()
    }

    companion object {
        private const val REQ = 51
        const val EXTRA_MODE = "mode"
        const val EXTRA_CAMERA = "camera"
        const val EXTRA_AUTO = "auto"
        @Volatile private var current: WeakReference<CaptureActivity>? = null

        fun start(ctx: Context, mode: String, camera: String, auto: Boolean = true): Boolean = try {
            ctx.startActivity(Intent(ctx, CaptureActivity::class.java).putExtra(EXTRA_MODE, mode).putExtra(EXTRA_CAMERA, camera)
                .putExtra(EXTRA_AUTO, auto).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
            true
        } catch (_: Exception) { false }

        /** "stop recording" (op capture_stop). */
        fun stop(): Boolean { val a = current?.get() ?: return false; a.runOnUiThread { a.stopRecording(close = true) }; return true }
    }
}
