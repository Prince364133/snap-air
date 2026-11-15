package live.snapy.app

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import org.json.JSONObject

/** Snapy's main screen: onboarding, Real Count dashboard and the assistant. */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        SnapyChannels.register(flutterEngine, this)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // "Hey Snapy" was turned on earlier: (re)start it now, while Snapy is in the foreground
        val core = CoreBridge.get(applicationContext)
        Thread {
            val wanted = try { JSONObject(core.configNowCall("voice_config")).optBoolean("wake_enabled") } catch (_: Exception) { false }
            if (wanted) runOnUiThread { WakeWordService.enable(applicationContext, true) }
        }.start()
    }
}
