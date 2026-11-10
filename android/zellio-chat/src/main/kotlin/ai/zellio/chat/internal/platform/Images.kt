package ai.zellio.chat.internal.platform

import ai.zellio.chat.internal.core.CappedCopy
import ai.zellio.chat.internal.core.FileNames
import ai.zellio.chat.internal.core.Guard
import ai.zellio.chat.internal.core.OutboxAttachment
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.provider.OpenableColumns
import android.util.LruCache
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.UUID

internal sealed interface ImageResult {
    data class Loaded(val bitmap: Bitmap) : ImageResult

    /** The URL expired (403): the thread reloads its page once to get fresh URLs. */
    data object Forbidden : ImageResult
    data object Failed : ImageResult
}

/** Memory and disk image cache. No image library: ~150 lines instead of a dependency. */
internal class ImageLoader(context: Context) {
    private val dir = File(context.cacheDir, "zellio-images").also { it.mkdirs() }
    private val memory = object : LruCache<String, Bitmap>(
        (Runtime.getRuntime().maxMemory() / 8).coerceAtMost(48L * 1024 * 1024).toInt(),
    ) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
    }
    private val aspects = java.util.concurrent.ConcurrentHashMap<String, Float>()

    /** Width / height once known, so the placeholder can have the real size. */
    internal fun knownAspect(key: String): Float? = aspects[key]

    internal fun cached(key: String): Bitmap? = memory.get(key)

    internal suspend fun load(url: String, maxEdgePx: Int): ImageResult = withContext(Dispatchers.IO) {
        try {
            val key = "$url@$maxEdgePx"
            memory.get(key)?.let { return@withContext ImageResult.Loaded(it) }
            if (!url.startsWith("https://", ignoreCase = true)) return@withContext ImageResult.Failed
            val file = File(dir, sha(url))
            if (!file.isFile) {
                val conn = URL(url).openConnection() as HttpURLConnection
                try {
                    conn.connectTimeout = 10_000
                    conn.readTimeout = 30_000
                    val status = conn.responseCode
                    if (status == 403 || status == 401) return@withContext ImageResult.Forbidden
                    if (status !in 200..299) return@withContext ImageResult.Failed
                    val tmp = File(dir, file.name + ".tmp")
                    try {
                        val declared = conn.contentLengthLong
                        if (declared > MAX_DOWNLOAD) return@withContext ImageResult.Failed
                        val ok = conn.inputStream.use { input -> tmp.outputStream().use { CappedCopy.copy(input, it, MAX_DOWNLOAD) } }
                        if (!ok || !tmp.renameTo(file)) return@withContext ImageResult.Failed
                    } finally {
                        if (tmp.exists()) tmp.delete()
                    }
                    trimDisk()
                } finally {
                    conn.disconnect()
                }
            }
            decode(file, maxEdgePx)?.let {
                aspects[url] = it.width.toFloat() / it.height
                memory.put(key, it)
                ImageResult.Loaded(it)
            } ?: ImageResult.Failed
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Throwable) {
            ImageResult.Failed
        }
    }

    internal suspend fun loadFile(path: String, maxEdgePx: Int): Bitmap? = withContext(Dispatchers.IO) {
        try {
            val key = "$path@$maxEdgePx"
            memory.get(key)?.let { return@withContext it }
            decode(File(path), maxEdgePx)?.also {
                aspects[path] = it.width.toFloat() / it.height
                memory.put(key, it)
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Throwable) {
            null
        }
    }

    internal fun aspectOfFile(path: String): Float? {
        aspects[path]?.let { return it }
        return try {
            val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, o)
            if (o.outWidth > 0 && o.outHeight > 0) (o.outWidth.toFloat() / o.outHeight).also { aspects[path] = it } else null
        } catch (_: Throwable) {
            null
        }
    }

    private fun decode(file: File, maxEdgePx: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= maxEdgePx && bounds.outHeight / (sample * 2) >= maxEdgePx) sample *= 2
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        return BitmapFactory.decodeFile(file.path, opts)
    }

    private fun trimDisk() {
        val files = dir.listFiles()?.filter { it.isFile }?.sortedBy { it.lastModified() } ?: return
        var total = files.sumOf { it.length() }
        for (f in files) {
            if (total <= DISK_LIMIT) break
            total -= f.length()
            f.delete()
        }
    }

    private fun sha(text: String): String =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }

    internal fun clearDisk() {
        Guard.run("clear images") { dir.deleteRecursively(); dir.mkdirs() }
        memory.evictAll()
    }

    private companion object {
        const val DISK_LIMIT = 48L * 1024 * 1024
        const val MAX_DOWNLOAD = 25L * 1024 * 1024
    }
}

internal sealed interface ImportResult {
    data class Ok(val attachment: OutboxAttachment) : ImportResult
    data object TooLarge : ImportResult
    data object TypeDenied : ImportResult
    data object Failed : ImportResult
}

/** Copies a picked or captured file into the SDK's private folder so it survives a restart. */
internal object AttachmentImport {
    internal const val MAX_BYTES = 10L * 1024 * 1024

    /** A photo this large can still be scaled down to fit [MAX_BYTES]. Anything else is stopped at [MAX_BYTES]. */
    internal const val MAX_SHRINKABLE_BYTES = 40L * 1024 * 1024
    private val allowed = setOf("image/jpeg", "image/png", "image/webp", "image/heic", "application/pdf")

    /** [knownMime] is for files the SDK made itself (a camera photo has a file URI, which has no type). */
    internal fun import(context: Context, uri: Uri, targetDir: File, knownMime: String? = null): ImportResult {
        var out: File? = null
        return try {
            val resolver = context.contentResolver
            val mime = (knownMime ?: resolver.getType(uri) ?: "application/octet-stream").lowercase()
            if (mime !in allowed) return ImportResult.TypeDenied
            var name = uri.lastPathSegment?.takeIf { it.isNotBlank() } ?: "file"
            var declared = -1L
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use {
                if (it.moveToFirst()) {
                    it.getString(0)?.let { n -> name = n }
                    if (!it.isNull(1)) declared = it.getLong(1)
                }
            }
            val shrinkable = mime.startsWith("image/") && mime != "image/heic"
            val cap = if (shrinkable) MAX_SHRINKABLE_BYTES else MAX_BYTES
            if (declared > cap) return ImportResult.TooLarge
            targetDir.mkdirs()
            val copy = File(targetDir, UUID.randomUUID().toString())
            out = copy
            val complete = resolver.openInputStream(uri)?.use { input -> copy.outputStream().use { CappedCopy.copy(input, it, cap) } }
                ?: return ImportResult.Failed
            if (!complete) return ImportResult.TooLarge
            var file = copy
            var finalMime = mime
            var finalName = name
            if (file.length() > MAX_BYTES && shrinkable) {
                val smaller = shrink(file, targetDir)
                if (smaller != null) {
                    file.delete()
                    file = smaller
                    out = smaller
                    finalMime = "image/jpeg"
                    finalName = FileNames.withJpegExtension(name)
                }
            }
            if (file.length() > MAX_BYTES) return ImportResult.TooLarge
            val result = ImportResult.Ok(OutboxAttachment(file.path, finalName, finalMime, file.length()))
            out = null
            result
        } catch (e: Throwable) {
            Guard.report("import attachment", e)
            ImportResult.Failed
        } finally {
            out?.delete()
        }
    }

    /** A very large photo is scaled down (as JPEG, rotated upright) so it fits [MAX_BYTES]. Returns null if that fails. */
    private fun shrink(source: File, targetDir: File): File? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(source.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val rotation = try {
            when (ExifInterface(source.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        } catch (_: Throwable) {
            0f
        }
        val target = File(targetDir, UUID.randomUUID().toString())
        var sample = 1
        while (sample <= 32) {
            var bitmap = try {
                BitmapFactory.decodeFile(source.path, BitmapFactory.Options().apply { inSampleSize = sample })
            } catch (_: OutOfMemoryError) {
                null
            }
            if (bitmap != null) {
                if (rotation != 0f) {
                    val turned = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, Matrix().apply { postRotate(rotation) }, true)
                    if (turned !== bitmap) bitmap.recycle()
                    bitmap = turned
                }
                target.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 88, it) }
                bitmap.recycle()
                if (target.length() in 1..MAX_BYTES) return target
            }
            sample *= 2
        }
        target.delete()
        return null
    }

}
