package live.snapy.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.ContactsContract
import org.json.JSONArray
import org.json.JSONObject

/**
 * Contact lookup for "call Rahul" / "WhatsApp Mom …", called by the shared brain.
 * Read-only and on-device; nothing is stored or uploaded.
 * Ranking: exact name > starts with > a word of the name > close spelling (typos, "Rahool").
 */
class Contacts(private val ctx: Context) {
    fun find(name: String): String {
        if (ctx.checkSelfPermission(Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            return JSONObject().put("error", "permission").toString()
        }
        val q = name.trim().lowercase()
        if (q.isEmpty()) return "[]"
        data class Hit(val name: String, val number: String, val score: Int)
        val hits = HashMap<String, Hit>()                         // best number per contact name
        val cols = arrayOf(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            ContactsContract.CommonDataKinds.Phone.NUMBER, ContactsContract.CommonDataKinds.Phone.IS_SUPER_PRIMARY)
        ctx.contentResolver.query(ContactsContract.CommonDataKinds.Phone.CONTENT_URI, cols, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val n = c.getString(0) ?: continue
                val num = c.getString(1) ?: continue
                val low = n.lowercase()
                val words = low.split(' ', '.', '-').filter { it.isNotEmpty() }
                val score = when {
                    low == q -> 100
                    low.startsWith(q) -> 80
                    words.any { it == q } -> 70
                    words.any { it.startsWith(q) && q.length >= 3 } -> 55
                    words.any { distance(it, q) <= (if (q.length > 5) 2 else 1) } -> 40
                    else -> 0
                } + (if (c.getInt(2) == 1) 1 else 0)
                if (score > 0 && (hits[n]?.score ?: -1) < score) hits[n] = Hit(n, num, score)
            }
        }
        val out = JSONArray()
        hits.values.sortedByDescending { it.score }.take(3).forEach { out.put(JSONObject().put("name", it.name).put("number", it.number)) }
        return out.toString()
    }

    private fun distance(a: String, b: String): Int {
        val d = Array(a.length + 1) { IntArray(b.length + 1) }
        for (i in 0..a.length) d[i][0] = i
        for (j in 0..b.length) d[0][j] = j
        for (i in 1..a.length) for (j in 1..b.length) {
            d[i][j] = minOf(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + if (a[i - 1] == b[j - 1]) 0 else 1)
        }
        return d[a.length][b.length]
    }
}
