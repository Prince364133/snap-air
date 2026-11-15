package live.snapy.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine

/**
 * Opened by tapping the Real Count pill: a see-through window showing Snapy's bottom sheet
 * over whatever app you're in (chat, voice, today's counts). Swipe down to return to the app.
 */
class SheetActivity : FlutterActivity() {
    override fun getInitialRoute(): String = "/sheet"
    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        SnapyChannels.register(flutterEngine, this)
    }
}
