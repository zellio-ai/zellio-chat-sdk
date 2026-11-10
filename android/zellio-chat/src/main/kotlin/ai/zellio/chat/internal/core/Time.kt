package ai.zellio.chat.internal.core

import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

internal fun interface Clock {
    fun now(): Long

    companion object {
        internal val System: Clock = Clock { java.lang.System.currentTimeMillis() }
    }
}

/** ISO 8601 parsing without java.time (minSdk 24 has no java.time without desugaring). */
internal object IsoTime {
    private val pattern = Regex("""^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:?\d{2})?$""")

    /** Returns epoch milliseconds, or null when the text is not a valid timestamp. */
    internal fun parse(text: String?): Long? {
        val m = pattern.matchEntire(text?.trim() ?: return null) ?: return null
        val g = m.groupValues
        val year = g[1].toInt()
        val month = g[2].toInt()
        val day = g[3].toInt()
        val hour = g[4].toInt()
        val minute = g[5].toInt()
        val second = g[6].toInt()
        if (month !in 1..12 || day !in 1..31 || hour > 23 || minute > 59 || second > 60) return null
        val millis = if (g[7].isEmpty()) 0 else g[7].padEnd(3, '0').substring(0, 3).toInt()
        var offsetMinutes = 0
        val zone = g[8]
        if (zone.isNotEmpty() && zone != "Z") {
            val sign = if (zone[0] == '-') -1 else 1
            val digits = zone.substring(1).replace(":", "")
            offsetMinutes = sign * (digits.substring(0, 2).toInt() * 60 + digits.substring(2).toInt())
        }
        val days = daysFromCivil(year, month, day)
        val seconds = days * 86_400L + hour * 3_600L + minute * 60L + second - offsetMinutes * 60L
        return seconds * 1000L + millis
    }

    // Howard Hinnant's days-from-civil algorithm.
    private fun daysFromCivil(y: Int, m: Int, d: Int): Long {
        val yy = if (m <= 2) y - 1 else y
        val era = (if (yy >= 0) yy else yy - 399) / 400
        val yoe = yy - era * 400
        val doy = (153 * (m + (if (m > 2) -3 else 9)) + 2) / 5 + d - 1
        val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097L + doe - 719468L
    }
}

/** Date separators and times. Digits are always Latin, in both languages. */
internal object DateLabels {
    internal enum class Kind { TODAY, YESTERDAY, DATE }

    internal fun dayKind(ms: Long, now: Long, zone: TimeZone): Kind {
        val diff = dayNumber(now, zone) - dayNumber(ms, zone)
        return when (diff) {
            0L -> Kind.TODAY
            1L -> Kind.YESTERDAY
            else -> Kind.DATE
        }
    }

    internal fun dayNumber(ms: Long, zone: TimeZone): Long = Math.floorDiv(ms + zone.getOffset(ms), 86_400_000L)

    internal fun localeForDigits(chatLocale: ChatLocale): Locale =
        Locale.forLanguageTag(if (chatLocale == ChatLocale.AR) "ar-u-nu-latn" else "en")

    internal fun time(ms: Long, chatLocale: ChatLocale, zone: TimeZone = TimeZone.getDefault()): String {
        val format = java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT, localeForDigits(chatLocale))
        format.timeZone = zone
        return format.format(ms)
    }

    internal fun date(ms: Long, chatLocale: ChatLocale, now: Long, zone: TimeZone = TimeZone.getDefault()): String {
        val cal = Calendar.getInstance(zone).apply { timeInMillis = ms }
        val sameYear = cal.get(Calendar.YEAR) == Calendar.getInstance(zone).apply { timeInMillis = now }.get(Calendar.YEAR)
        val pattern = if (sameYear) "d MMMM" else "d MMMM yyyy"
        val format = java.text.SimpleDateFormat(pattern, localeForDigits(chatLocale))
        format.timeZone = zone
        return format.format(ms)
    }
}
