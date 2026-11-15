package live.snapy.app

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.json.JSONArray

/**
 * Reminders as real Android alarms, so they fire even when Snapy isn't running.
 * The shared brain sends the full list of upcoming reminders after every change;
 * we (re)schedule each one by task id. Exact alarms are used when the user allowed
 * them, otherwise a short window (Android may deliver a few minutes late).
 */
object Reminders {
    const val CHANNEL = "snapy_reminders"
    private const val PREFS = "snapy_reminders"

    fun sync(ctx: Context, items: JSONArray) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val keep = HashSet<String>()
        val now = System.currentTimeMillis()
        for (i in 0 until items.length()) {
            val it = items.getJSONObject(i)
            val id = it.getString("id")
            val at = it.getLong("at_ms")
            if (at <= now - 60_000) continue
            keep.add(id)
            val pi = pending(ctx, id, it.getString("title"))
            if (Build.VERSION.SDK_INT >= 31 && !am.canScheduleExactAlarms()) {
                am.setWindow(AlarmManager.RTC_WAKEUP, at, 5 * 60_000L, pi)
            } else {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            }
        }
        // cancel reminders that were completed or deleted
        for (old in prefs.getStringSet("ids", emptySet())!!) if (old !in keep) am.cancel(pending(ctx, old, ""))
        prefs.edit().putStringSet("ids", keep).apply()
    }

    private fun pending(ctx: Context, id: String, title: String): PendingIntent =
        PendingIntent.getBroadcast(ctx, id.hashCode(),
            Intent(ctx, ReminderReceiver::class.java).putExtra("id", id).putExtra("title", title),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    fun ensureChannel(ctx: Context) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Reminders", NotificationManager.IMPORTANCE_HIGH)
                .apply { description = "Reminders you set with Snapy" })
        }
    }
}

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val id = intent.getStringExtra("id") ?: return
        val title = intent.getStringExtra("title") ?: "Reminder"
        Reminders.ensureChannel(ctx)
        val open = PendingIntent.getActivity(ctx, 0, Intent(ctx, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = NotificationCompat.Builder(ctx, Reminders.CHANNEL)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle("Snapy reminder")
            .setContentText(title)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        try { NotificationManagerCompat.from(ctx).notify(id.hashCode(), n) } catch (_: SecurityException) { }
        CoreBridge.get(ctx).reminderFired(id)
    }
}
