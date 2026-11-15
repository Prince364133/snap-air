package live.snapy.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import kotlin.math.max
import kotlin.math.min

/**
 * Dynamically extracts signature color gradients from the launcher icon of ANY installed app
 * at runtime without hardcoding. Samples dominant vibrant hues and generates harmonic 4-stop
 * spectral gradients for the camera halo ring.
 */
object AppPaletteExtractor {
    private val cache = HashMap<String, IntArray>()

    fun extract(ctx: Context, packageName: String): IntArray? {
        if (packageName.isEmpty() || packageName == ctx.packageName || packageName == "com.android.systemui") {
            return null
        }
        cache[packageName]?.let { return it }

        return try {
            val pm = ctx.packageManager
            val drawable = pm.getApplicationIcon(packageName)
            val bmp = drawableToBitmap(drawable)
            val colors = extractVibrantColors(bmp)
            cache[packageName] = colors
            colors
        } catch (_: Exception) {
            null
        }
    }

    private fun drawableToBitmap(d: Drawable): Bitmap {
        if (d is BitmapDrawable && d.bitmap != null && !d.bitmap.isRecycled) {
            return Bitmap.createScaledBitmap(d.bitmap, 48, 48, false)
        }
        val bmp = Bitmap.createBitmap(48, 48, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        d.setBounds(0, 0, 48, 48)
        d.draw(canvas)
        return bmp
    }

    private fun extractVibrantColors(bmp: Bitmap): IntArray {
        val w = bmp.width
        val h = bmp.height
        val pixels = IntArray(w * h)
        bmp.getPixels(pixels, 0, w, 0, 0, w, h)

        var bestColor = 0
        var maxSat = -1f
        val colorCounts = HashMap<Int, Int>()

        for (p in pixels) {
            val a = Color.alpha(p)
            if (a < 120) continue
            val r = Color.red(p)
            val g = Color.green(p)
            val b = Color.blue(p)

            val maxC = max(r, max(g, b))
            val minC = min(r, min(g, b))
            val diff = maxC - minC
            // Exclude nearly pure black, white, or low-saturation grays
            if (maxC < 38 || minC > 232 || diff < 18) continue

            val qr = (r / 16) * 16
            val qg = (g / 16) * 16
            val qb = (b / 16) * 16
            val qColor = Color.rgb(qr, qg, qb)
            colorCounts[qColor] = (colorCounts[qColor] ?: 0) + 1

            val hsv = FloatArray(3)
            Color.colorToHSV(p, hsv)
            if (hsv[1] > maxSat && hsv[2] > 0.35f) {
                maxSat = hsv[1]
                bestColor = p
            }
        }

        val dominant = colorCounts.entries.maxByOrNull { it.value }?.key ?: bestColor
        val primary = if (dominant != 0) dominant else 0xFF28C8FF.toInt()

        val hsv = FloatArray(3)
        Color.colorToHSV(primary, hsv)

        // Generate harmonic secondary and tertiary accents
        val h1 = (hsv[0] + 28f) % 360f
        val c2 = Color.HSVToColor(floatArrayOf(h1, min(hsv[1] * 1.15f, 1f), max(hsv[2] * 0.92f, 0.45f)))

        val h2 = (hsv[0] + 55f) % 360f
        val c3 = Color.HSVToColor(floatArrayOf(h2, max(hsv[1] * 0.85f, 0.5f), min(hsv[2] * 1.08f, 1f)))

        return intArrayOf(0xFFFFFFFF.toInt(), primary, c2, c3)
    }
}
