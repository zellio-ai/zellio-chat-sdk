package ai.zellio.chat.internal.core

import kotlin.math.pow
import kotlin.math.roundToInt

/** Port of packages/zeechat-ui/src/color-contrast.ts. Colors are `#RRGGBB` strings. */
internal object Contrast {
    internal const val BLACK = "#000000"
    internal const val WHITE = "#FFFFFF"

    private fun channels(color: String): IntArray {
        val hex = color.trim().removePrefix("#")
        if (hex.length != 6) return intArrayOf(0, 0, 0)
        val values = IntArray(3) { hex.substring(it * 2, it * 2 + 2).toIntOrNull(16) ?: return intArrayOf(0, 0, 0) }
        return values
    }

    internal fun toHex(r: Int, g: Int, b: Int): String =
        "#" + listOf(r, g, b).joinToString("") { it.coerceIn(0, 255).toString(16).padStart(2, '0') }.uppercase()

    internal fun normalize(color: String): String = channels(color).let { toHex(it[0], it[1], it[2]) }

    internal fun toArgb(color: String): Int {
        val c = channels(color)
        return (0xFF shl 24) or (c[0] shl 16) or (c[1] shl 8) or c[2]
    }

    /** WCAG relative luminance. */
    internal fun luminance(color: String): Double {
        val c = channels(color).map {
            val v = it / 255.0
            if (v <= 0.04045) v / 12.92 else ((v + 0.055) / 1.055).pow(2.4)
        }
        return c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722
    }

    internal fun ratio(a: String, b: String): Double {
        val la = luminance(a)
        val lb = luminance(b)
        return (maxOf(la, lb) + 0.05) / (minOf(la, lb) + 0.05)
    }

    internal data class Readable(val foreground: String, val ratio: Double)

    /** The better of black and white always exceeds 4.5:1. */
    internal fun readable(background: String): Readable {
        val black = ratio(background, BLACK)
        val white = ratio(background, WHITE)
        return if (black >= white) Readable(BLACK, black) else Readable(WHITE, white)
    }

    /** `base` mixed with `other` by `otherShare` (0..1), like CSS `color-mix(in srgb, ...)`. */
    internal fun mix(base: String, other: String, otherShare: Double): String {
        val a = channels(base)
        val b = channels(other)
        return toHex(
            (a[0] + (b[0] - a[0]) * otherShare).roundToInt(),
            (a[1] + (b[1] - a[1]) * otherShare).roundToInt(),
            (a[2] + (b[2] - a[2]) * otherShare).roundToInt(),
        )
    }

    private fun toHsl(color: String): DoubleArray {
        val c = channels(color).map { it / 255.0 }
        val r = c[0]
        val g = c[1]
        val b = c[2]
        val max = maxOf(r, g, b)
        val min = minOf(r, g, b)
        val light = (max + min) / 2
        if (max == min) return doubleArrayOf(0.0, 0.0, light)
        val delta = max - min
        val saturation = if (light > 0.5) delta / (2 - max - min) else delta / (max + min)
        val hue = when (max) {
            r -> (g - b) / delta + (if (g < b) 6 else 0)
            g -> (b - r) / delta + 2
            else -> (r - g) / delta + 4
        }
        return doubleArrayOf(hue / 6, saturation, light)
    }

    private fun fromHsl(hue: Double, saturation: Double, light: Double): String {
        val q = if (light < 0.5) light * (1 + saturation) else light + saturation - light * saturation
        val p = 2 * light - q
        fun channel(t0: Double): Int {
            val t = if (t0 < 0) t0 + 1 else if (t0 > 1) t0 - 1 else t0
            val v = when {
                t < 1.0 / 6 -> p + (q - p) * 6 * t
                t < 1.0 / 2 -> q
                t < 2.0 / 3 -> p + (q - p) * (2.0 / 3 - t) * 6
                else -> p
            }
            return (v * 255).roundToInt()
        }
        return toHex(channel(hue + 1.0 / 3), channel(hue), channel(hue - 1.0 / 3))
    }

    private const val LIGHT_BRAND = 0.4

    /**
     * A brand color for surfaces that carry text. Mid-tone brands keep their hue and get darker until white
     * text passes 4.5:1, instead of switching to black text.
     */
    internal fun brandSurface(color: String): Pair<String, String> {
        val base = normalize(color)
        if (ratio(base, WHITE) >= 4.5) return base to WHITE
        if (luminance(base) > LIGHT_BRAND) return base to BLACK
        val hsl = toHsl(base)
        var next = hsl[2]
        while (next >= 0) {
            val shade = fromHsl(hsl[0], hsl[1], next)
            if (ratio(shade, WHITE) >= 4.5) return shade to WHITE
            next -= 0.01
        }
        return BLACK to WHITE
    }
}
