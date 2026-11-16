package live.snapy.app

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import org.json.JSONObject

/**
 * Actions that need an unlocked phone ("open YouTube", WhatsApp, maps…) asked while it is
 * locked (docs/ANDROID_NEXT_PLAN.md §0): Snapy asks Android to show the user's own unlock
 * (KeyguardManager.requestDismissKeyguard — fingerprint/face/PIN typed by the user on the
 * system screen) and then finishes the queued action automatically. Snapy never asks for,
 * stores or types the device PIN.
 */
class UnlockActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ListenActivity.showOverLockScreen(this)
        val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (!km.isKeyguardLocked) { runQueued(); finish(); return }
        km.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
            override fun onDismissSucceeded() { runQueued(); finish() }
            override fun onDismissCancelled() { dropQueued(); finish() }
            override fun onDismissError() { dropQueued(); finish() }
        })
    }

    private fun runQueued() {
        val ops = synchronized(queue) { ArrayList(queue).also { queue.clear() } }
        val ex = OpExecutor(applicationContext)
        for (op in ops) ex.runOp(op.put(UNLOCKED, true))
    }

    private fun dropQueued() {
        synchronized(queue) { queue.clear() }
        val t = Strings.t(this, "unlock.cancelled").let { if (it == "unlock.cancelled") "Unlock your phone and ask again to finish that." else it }
        CoreBridge.get(this).publish(JSONObject().put("type", "toast").put("text", t))
    }

    companion object {
        const val UNLOCKED = "_unlocked"
        private val queue = ArrayList<JSONObject>()

        /** Ops that open another app's UI (they would be hidden behind the lock screen). */
        private val needsUnlock = setOf("open_url", "launch_app", "whatsapp_send", "sms", "navigate", "panel", "type_text", "screen_tap", "alarm", "timer")

        /** True when [op] was queued behind the unlock prompt (the caller must not run it now). */
        fun deferIfLocked(ctx: Context, op: JSONObject): Boolean {
            if (op.optBoolean(UNLOCKED) || op.optString("op") !in needsUnlock) return false
            val km = ctx.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            if (!km.isKeyguardLocked) return false
            synchronized(queue) { queue.add(op) }
            return try {
                ctx.startActivity(Intent(ctx, UnlockActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION))
                true
            } catch (_: Exception) { synchronized(queue) { queue.remove(op) }; false }
        }
    }
}
