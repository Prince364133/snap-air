package live.snapy.app

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat

/**
 * After a restart (or an app update): put Real Count back the way the user left it.
 *  - The Reel counter (accessibility service) is rebound by Android itself, with its own chip.
 *  - Otherwise the fallback chip (ChipService, foreground type specialUse) is started — allowed
 *    from BOOT_COMPLETED.
 *  - "Hey Snapy": Android 11+ doesn't give a microphone service started from the background
 *    (including boot) access to the mic, and Android 14/15 refuse to start it at all, so on
 *    those versions Snapy posts a one-tap notification that reopens it (MainActivity restarts
 *    the wake word from the foreground). On Android 10 and older it starts directly.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        ChipService.startIfWanted(ctx)
        val prefs = RcPrefs(ctx)
        if (!prefs.bool(RcPrefs.WAKE_WANTED)) return
        if (Build.VERSION.SDK_INT < 30) {
            try { WakeWordService.enable(ctx, true) } catch (_: Exception) { }
            return
        }
        postWakeResume(ctx)
    }

    companion object {
        private const val CHANNEL = "snapy_boot"

        /** "Tap to turn “Hey Snapy” back on": opening Snapy restarts it from the foreground (MainActivity). */
        fun postWakeResume(ctx: Context) {
            try {
                if (Build.VERSION.SDK_INT >= 33 &&
                    ctx.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
                val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (nm.getNotificationChannel(CHANNEL) == null) {
                    nm.createNotificationChannel(NotificationChannel(CHANNEL, Strings.t(ctx, "notif.wake_title"), NotificationManager.IMPORTANCE_LOW))
                }
                val open = PendingIntent.getActivity(ctx, 0, Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    PendingIntent.FLAG_IMMUTABLE)
                nm.notify(9, NotificationCompat.Builder(ctx, CHANNEL)
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle(Strings.t(ctx, "notif.wake_title"))
                    .setContentText(Strings.t(ctx, "notif.wake_text"))
                    .setAutoCancel(true)
                    .setContentIntent(open)
                    .build())
            } catch (_: Throwable) { }
        }
    }
}
