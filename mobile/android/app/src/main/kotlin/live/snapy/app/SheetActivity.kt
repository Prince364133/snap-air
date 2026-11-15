package live.snapy.app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Opened from the chip: a see-through window over whatever app you're in.
 * Routes: /sheet (Snapy's bottom sheet), /reset?app=… (2-minute reset), /break?app=…&s=10 (opt-in pause).
 * Single-task: a new route while it's open goes to Flutter over "snapy/sheet".
 */
class SheetActivity : FlutterActivity() {
    private var sheetChannel: MethodChannel? = null

    override fun getInitialRoute(): String = intent?.getStringExtra("route") ?: "/sheet"
    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        SnapyChannels.register(flutterEngine, this)
        sheetChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "snapy/sheet")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        sheetChannel?.invokeMethod("route", intent.getStringExtra("route") ?: "/sheet")
    }
}
