package live.snapy.app

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

// The shared core config tree (core/rules json files, deep-merged in core/manifest.json order),
// read straight from the APK Flutter assets (assets/core/, copied by tool/sync_core.dart).
// Pure data, so Kotlin can read it synchronously on any thread (OpExecutor, the Real Count
// service). The Dart runtime loads the same files and also enforces one source per leaf;
// this reader only merges.
object CoreConfig {
    @Volatile private var tree: JSONObject? = null

    fun tree(ctx: Context): JSONObject = tree ?: synchronized(this) {
        tree ?: load(ctx.applicationContext).also { tree = it }
    }

    private fun read(ctx: Context, rel: String): String =
        ctx.assets.open("flutter_assets/assets/core/$rel").bufferedReader(Charsets.UTF_8).use { it.readText() }

    private fun load(ctx: Context): JSONObject {
        val out = JSONObject()
        try {
            val manifest = JSONObject(read(ctx, "manifest.json"))
            val frags = manifest.optJSONArray("config") ?: JSONArray()
            for (i in 0 until frags.length()) {
                val frag = JSONObject(read(ctx, frags.getString(i)))
                frag.remove("_meta")
                merge(out, frag)
            }
        } catch (_: Exception) {
            // assets missing (should not happen in a built APK): callers get null values
        }
        return out
    }

    private fun merge(base: JSONObject, extra: JSONObject) {
        val keys = extra.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            val v = extra.get(k)
            val old = base.opt(k)
            if (v is JSONObject && old is JSONObject) merge(old, v) else base.put(k, v)
        }
    }

    // The value at a dotted path, or null.
    fun value(ctx: Context, dotted: String): Any? {
        var node: Any? = tree(ctx)
        for (part in dotted.split('.')) {
            node = (node as? JSONObject)?.opt(part) ?: return null
        }
        return node
    }

    // The value at a dotted path as JSON text ("null" when missing) - the old configNow contract.
    fun json(ctx: Context, dotted: String): String = when (val v = value(ctx, dotted)) {
        null, JSONObject.NULL -> "null"
        is JSONObject, is JSONArray -> v.toString()
        is String -> JSONObject.quote(v)
        else -> v.toString()
    }
}
