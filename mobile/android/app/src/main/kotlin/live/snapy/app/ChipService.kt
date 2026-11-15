package live.snapy.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import androidx.core.app.NotificationCompat

/**
 * The chip without the Reel counter: shown with "Display over other apps"
 * (TYPE_APPLICATION_OVERLAY) when the accessibility service is off. Screen time only; the app in
 * front is polled from usage events every few seconds while the screen is on.
 * A foreground service (type specialUse, minimum-importance notification) so Android doesn't
 * stop it in the background. Stops itself as soon as the Reel counter is turned on.
 */
class ChipService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private var rc: RealCountController? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!canRun(this) || intent?.action == ACTION_STOP) { stopSelf(); return START_NOT_STICKY }
        startInForeground()
        if (rc == null) {
            rc = RealCountController(this, WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, counting = false).also { it.start() }
            poll()
        } else {
            rc?.reload()
        }
        return START_STICKY
    }

    private fun poll() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (pm.isInteractive) rc?.pollForeground()
        main.postDelayed({ if (rc != null) poll() }, POLL_MS)
    }

    private fun startInForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, Strings.t(this, "notif.chip_channel"), NotificationManager.IMPORTANCE_MIN))
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val n: Notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_recent_history)
            .setContentTitle(Strings.t(this, "notif.chip_title"))
            .setContentText(Strings.t(this, "notif.chip_text"))
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setContentIntent(open)
            .build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        else startForeground(NOTIF_ID, n)
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        rc?.stop()
        rc = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "snapy_chip"
        private const val NOTIF_ID = 8
        private const val ACTION_STOP = "stop"
        private const val POLL_MS = 4000L

        /** Allowed + wanted + the Reel counter (which has its own chip) is off. */
        fun canRun(ctx: Context): Boolean {
            val p = RcPrefs(ctx)
            return Build.VERSION.SDK_INT >= 26 && Settings.canDrawOverlays(ctx) && p.bool("chip_enabled") &&
                p.bool("overlay_fallback") && SnapyAccessibilityService.instance == null
        }

        /** Returns true if it was (re)started. Call from the foreground (app open) or BOOT_COMPLETED. */
        fun startIfWanted(ctx: Context): Boolean {
            if (!canRun(ctx)) { stop(ctx); return false }
            return try {
                ctx.startForegroundService(Intent(ctx, ChipService::class.java)); true
            } catch (_: Exception) { false }                         // background-start limits: next app open retries
        }

        fun stop(ctx: Context) {
            try { ctx.stopService(Intent(ctx, ChipService::class.java)) } catch (_: Exception) { }
        }
    }
}
