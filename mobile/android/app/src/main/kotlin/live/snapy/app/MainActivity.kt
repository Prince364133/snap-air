package live.snapy.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/** Snapy's main screen: onboarding, Real Count dashboard and the assistant. */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        SnapyChannels.register(flutterEngine, this)
    }
}
