package live.snapy.app

import android.content.Context
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File

/**
 * Secrets, encrypted with the Android Keystore key (KeyCipher, AES-256-GCM), for every Flutter
 * engine over "snapy/keystore":
 *   read / write / delete        snapy/keystore.json  (lib/sync: X25519 identity, paired laptops)
 *   apiKeyGet / apiKeySet        snapy/secrets.json   (AI provider keys; the same file and format
 *                                                     the Chaquopy brain used, so saved keys survive)
 * Values are base64(IV + ciphertext). Nothing is logged.
 */
object SecureFiles {
    private val cipher = KeyCipher()
    private val lock = Any()

    private fun file(ctx: Context, name: String) = File(ctx.filesDir, "snapy/$name").also { it.parentFile?.mkdirs() }

    private fun load(f: File): JSONObject = try { if (f.exists()) JSONObject(f.readText(Charsets.UTF_8)) else JSONObject() } catch (_: Exception) { JSONObject() }

    private fun save(f: File, o: JSONObject) {
        val tmp = File(f.path + ".tmp")
        tmp.writeText(o.toString(2), Charsets.UTF_8)
        if (!tmp.renameTo(f)) { f.delete(); tmp.renameTo(f) }
    }

    fun get(ctx: Context, fileName: String, key: String): String? = synchronized(lock) {
        val o = load(file(ctx, fileName))
        val b = o.optString(key, "").takeIf { it.isNotEmpty() } ?: return null
        try { String(cipher.decrypt(Base64.decode(b, Base64.DEFAULT)), Charsets.UTF_8) } catch (_: Exception) { null }
    }

    fun put(ctx: Context, fileName: String, key: String, value: String?) = synchronized(lock) {
        val f = file(ctx, fileName)
        val o = load(f)
        if (value.isNullOrEmpty()) o.remove(key)
        else o.put(key, Base64.encodeToString(cipher.encrypt(value.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP))
        save(f, o)
    }

    fun register(messenger: BinaryMessenger, ctx: Context) {
        val app = ctx.applicationContext
        MethodChannel(messenger, "snapy/keystore").setMethodCallHandler { call, result ->
            // off the main thread: Keystore operations can take tens of milliseconds
            Thread {
                try {
                    val r: Any? = when (call.method) {
                        "read" -> get(app, "keystore.json", call.argument<String>("key") ?: "")
                        "write" -> { put(app, "keystore.json", call.argument<String>("key") ?: "", call.argument<String>("value")); true }
                        "delete" -> { put(app, "keystore.json", call.argument<String>("key") ?: "", null); true }
                        "apiKeyGet" -> get(app, "secrets.json", call.argument<String>("name") ?: "") ?: ""
                        "apiKeySet" -> { put(app, "secrets.json", call.argument<String>("name") ?: "", call.argument<String>("value")?.trim()); true }
                        else -> { CoreBridge.mainHandler.post { result.notImplemented() }; return@Thread }
                    }
                    CoreBridge.mainHandler.post { result.success(r) }
                } catch (e: Exception) {
                    CoreBridge.mainHandler.post { result.error("keystore", e.javaClass.simpleName, null) }
                }
            }.start()
        }
    }
}
