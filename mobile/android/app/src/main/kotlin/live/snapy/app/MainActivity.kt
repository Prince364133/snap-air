package live.snapy.app

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/** Snapy's main screen: onboarding, Real Count dashboard and the assistant. */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        try {
            SnapyChannels.register(flutterEngine, this)
        } catch (t: Throwable) {
            android.util.Log.e("MainActivity", "Error configuring FlutterEngine", t)
        }
    }


    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            // "Hey Snapy" was turned on earlier: (re)start it now, while Snapy is in the foreground
            val core = CoreBridge.get(applicationContext)
            core.voiceConfig { cfg ->
                val wanted = cfg.optBoolean("wake_enabled")
                RcPrefs(applicationContext).putBool(RcPrefs.WAKE_WANTED, wanted)      // remembered for after a reboot
                if (wanted) WakeWordService.enable(applicationContext, true)
            }
        } catch (t: Throwable) {
            android.util.Log.e("MainActivity", "Error during onCreate background setup", t)
        }
    }

    override fun onResume() {
        super.onResume()
        try {
            // the chip without the Reel counter ("Display over other apps"): start it from the foreground
            ChipService.startIfWanted(applicationContext)
        } catch (t: Throwable) {
            android.util.Log.e("MainActivity", "Error during onResume chip setup", t)
        }
    }
}
