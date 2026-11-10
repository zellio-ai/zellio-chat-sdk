package ai.zellio.chat.internal.core

import java.io.InputStream
import java.io.OutputStream

internal object CappedCopy {
    /** Copies at most [maxBytes]. Returns false when the source has more (the caller deletes the partial output). */
    internal fun copy(input: InputStream, output: OutputStream, maxBytes: Long): Boolean {
        val buffer = ByteArray(16 * 1024)
        var total = 0L
        while (true) {
            val n = input.read(buffer)
            if (n < 0) return true
            total += n
            if (total > maxBytes) return false
            output.write(buffer, 0, n)
        }
    }
}

internal object FileNames {
    /** "IMG_1.png" -> "IMG_1.jpg". A name without extension gets one. */
    internal fun withJpegExtension(name: String): String {
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        return "$base.jpg"
    }
}
