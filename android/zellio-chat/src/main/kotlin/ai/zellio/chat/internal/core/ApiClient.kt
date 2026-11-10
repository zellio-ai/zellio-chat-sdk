package ai.zellio.chat.internal.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.io.BufferedReader
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.InputStreamReader
import java.net.HttpRetryException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.UUID

internal data class HttpTimeouts(
    val connectMs: Int = 10_000,
    val readMs: Int = 30_000,
    val uploadMs: Int = 120_000,
    /** Nothing arrives for this long on the event stream: the stream is dead. The server pings every 20 s. */
    val streamDeadMs: Int = 45_000,
)

/**
 * Contract v1 client on `HttpURLConnection`: no dependency, no native code, nothing added to the 2 MB budget.
 * Every call is a suspend function on the IO dispatcher and aborts its socket when the coroutine is cancelled.
 */
internal class ApiClient(
    baseUrl: String,
    private val appKey: String,
    private val sdkVersion: String,
    private val wrapper: String? = null,
    private val sessionToken: () -> String?,
    private val timeouts: HttpTimeouts = HttpTimeouts(),
) {
    private val base = baseUrl.trimEnd('/') + "/api/v1/zeechat/mobile"

    private class Raw(val status: Int, val body: String, val retryAfter: String?)

    // ---- endpoints ----

    internal suspend fun config(): ConfigData =
        data(request("GET", "/config", auth = false), ConfigData.serializer())

    internal suspend fun createSession(req: SessionRequest): SessionData =
        data(request("POST", "/session", body = encode(SessionRequest.serializer(), req), auth = false), SessionData.serializer())

    internal suspend fun identify(identityToken: String): SessionData =
        data(request("POST", "/session/identify", body = encode(IdentifyRequest.serializer(), IdentifyRequest(identityToken))), SessionData.serializer())

    internal suspend fun logout() {
        request("POST", "/session/logout", body = "{}")
    }

    internal suspend fun conversations(cursor: String? = null, limit: Int = 20): ConversationsPage =
        Decoders.conversations(data(request("GET", "/conversations", query = listOf("cursor" to cursor, "limit" to limit.toString())), ConversationsData.serializer()))

    internal suspend fun messages(conversationId: String, before: String? = null, after: String? = null, limit: Int = 50): MessagesPage {
        // `before` and `after` are never sent together.
        val query = listOf("before" to before, "after" to if (before == null) after else null, "limit" to limit.toString())
        return Decoders.messages(data(request("GET", "/conversations/${enc(conversationId)}/messages", query = query), MessagesData.serializer()))
    }

    internal suspend fun send(req: SendRequest): SendResult =
        data(request("POST", "/messages", body = encode(SendRequest.serializer(), req)), SendResult.serializer())

    internal suspend fun uploadAttachment(file: File, name: String, mimeType: String, onProgress: (Float) -> Unit): UploadedAttachment =
        data(upload(file, name, mimeType, onProgress), UploadedAttachment.serializer())

    internal suspend fun read(conversationId: String, upTo: String): Int =
        data(request("POST", "/read", body = encode(ReadRequest.serializer(), ReadRequest(conversationId, upTo))), UnreadData.serializer()).unreadTotal

    internal suspend fun unread(): Int = data(request("GET", "/unread"), UnreadData.serializer()).unreadTotal

    internal suspend fun putDevice(req: DeviceRequest) {
        request("PUT", "/device", body = encode(DeviceRequest.serializer(), req))
    }

    internal suspend fun deleteDevice() {
        request("DELETE", "/device")
    }

    // ---- SSE ----

    /**
     * Opens `/events` and calls [onEvent] for every event until the server closes the stream (returns) or
     * something fails (throws). Cancelling the coroutine closes the socket.
     */
    internal suspend fun events(onOpen: () -> Unit, onEvent: (SseEvent) -> Unit) {
        withContext(Dispatchers.IO) {
            val conn = open("GET", "/events", emptyList(), auth = true)
            val guard = attachCancel(conn)
            try {
                conn.setRequestProperty("Accept", "text/event-stream")
                conn.readTimeout = timeouts.streamDeadMs
                val status = conn.responseCode
                if (status !in 200..299) {
                    val body = readBody(conn)
                    throw ErrorBodies.parse(status, body, conn.getHeaderField("Retry-After"))
                }
                onOpen()
                BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8)).use { reader ->
                    SseParser.readAll(reader, onEvent = { onEvent(it) })
                }
            } catch (e: IOException) {
                rethrowIo(e, conn)
            } finally {
                guard.dispose()
                conn.disconnect()
            }
        }
    }

    // ---- plumbing ----

    private fun enc(value: String) = URLEncoder.encode(value, "UTF-8").replace("+", "%20")

    private fun <T> encode(serializer: KSerializer<T>, value: T): String = ChatJson.encodeToString(serializer, value)

    private fun <T> data(raw: Raw, serializer: KSerializer<T>): T {
        val root = try {
            ChatJson.parseToJsonElement(raw.body)
        } catch (e: Exception) {
            throw ApiException(raw.status, null, "BAD_BODY")
        }
        val payload: JsonElement = (root as? JsonObject)?.get("data") ?: throw ApiException(raw.status, null, "BAD_BODY")
        return try {
            ChatJson.decodeFromJsonElement(serializer, payload)
        } catch (e: Exception) {
            throw ApiException(raw.status, null, "BAD_BODY")
        }
    }

    private fun open(method: String, path: String, query: List<Pair<String, String?>>, auth: Boolean): HttpURLConnection {
        val q = query.filter { it.second != null }.joinToString("&") { "${it.first}=${enc(it.second!!)}" }
        val url = URL(base + path + if (q.isEmpty()) "" else "?$q")
        val conn = url.openConnection() as HttpURLConnection
        conn.requestMethod = method
        conn.connectTimeout = timeouts.connectMs
        conn.readTimeout = timeouts.readMs
        conn.instanceFollowRedirects = false
        conn.useCaches = false
        conn.setRequestProperty("x-zee-app-key", appKey)
        conn.setRequestProperty("x-zee-sdk", "android/$sdkVersion")
        if (wrapper != null) conn.setRequestProperty("x-zee-sdk-wrapper", wrapper)
        conn.setRequestProperty("Accept", "application/json")
        if (auth) sessionToken()?.let { conn.setRequestProperty("x-zee-session-token", it) }
        return conn
    }

    /** Aborts the socket the moment the coroutine is cancelled (blocking IO cannot be interrupted otherwise). */
    private fun CoroutineScope.attachCancel(conn: HttpURLConnection): kotlinx.coroutines.DisposableHandle {
        val finished = java.util.concurrent.atomic.AtomicBoolean(false)
        val watcher = launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                awaitCancellation()
            } finally {
                if (!finished.get()) conn.disconnect()
            }
        }
        return kotlinx.coroutines.DisposableHandle {
            finished.set(true)
            watcher.cancel()
        }
    }

    /** A 401 on a streamed upload surfaces as [HttpRetryException]: the code is still read from the error body. */
    private fun rethrowIo(e: IOException, conn: HttpURLConnection? = null): Nothing {
        if (e is HttpRetryException) {
            val body = try {
                conn?.errorStream?.use { it.readBytes().toString(Charsets.UTF_8) }
            } catch (_: Exception) {
                null
            }
            throw ErrorBodies.parse(e.responseCode(), body, null)
        }
        throw NetworkException(e)
    }

    private fun readBody(conn: HttpURLConnection): String {
        val stream = try {
            if (conn.responseCode >= 400) conn.errorStream else conn.inputStream
        } catch (_: IOException) {
            null
        } ?: return ""
        return stream.use { it.readBytes().toString(Charsets.UTF_8) }
    }

    private suspend fun request(
        method: String,
        path: String,
        query: List<Pair<String, String?>> = emptyList(),
        body: String? = null,
        auth: Boolean = true,
    ): Raw = withContext(Dispatchers.IO) {
        val conn = open(method, path, query, auth)
        val guard = attachCancel(conn)
        try {
            if (body != null) {
                val bytes = body.toByteArray(Charsets.UTF_8)
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                // Small JSON body: buffered on purpose. A streamed POST turns a 401 into an exception that hides the error code.
                conn.outputStream.use { it.write(bytes) }
            }
            val status = conn.responseCode
            val text = readBody(conn)
            if (status !in 200..299) throw ErrorBodies.parse(status, text, conn.getHeaderField("Retry-After"))
            Raw(status, text, null)
        } catch (e: IOException) {
            currentCoroutineContext().ensureActive()
            rethrowIo(e, conn)
        } finally {
            guard.dispose()
            conn.disconnect()
        }
    }

    private suspend fun upload(file: File, name: String, mimeType: String, onProgress: (Float) -> Unit): Raw =
        withContext(Dispatchers.IO) {
            val boundary = "zellio-" + UUID.randomUUID().toString()
            val safeName = name.replace("\"", "").replace("\r", "").replace("\n", "")
            val head = ("--$boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"$safeName\"\r\n" +
                "Content-Type: $mimeType\r\n\r\n").toByteArray(Charsets.UTF_8)
            val tail = "\r\n--$boundary--\r\n".toByteArray(Charsets.UTF_8)
            val total = head.size + file.length() + tail.size
            val conn = open("POST", "/attachments", emptyList(), auth = true)
            val guard = attachCancel(conn)
            try {
                conn.readTimeout = timeouts.uploadMs
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
                conn.setFixedLengthStreamingMode(total)
                var sent = 0L
                conn.outputStream.use { out ->
                    out.write(head)
                    sent += head.size
                    FileInputStream(file).use { input ->
                        val buffer = ByteArray(16 * 1024)
                        while (true) {
                            ensureActive()
                            val n = input.read(buffer)
                            if (n < 0) break
                            out.write(buffer, 0, n)
                            sent += n
                            onProgress((sent.toFloat() / total).coerceIn(0f, 1f))
                        }
                    }
                    out.write(tail)
                }
                val status = conn.responseCode
                val text = readBody(conn)
                if (status !in 200..299) throw ErrorBodies.parse(status, text, conn.getHeaderField("Retry-After"))
                onProgress(1f)
                Raw(status, text, null)
            } catch (e: IOException) {
                ensureActive()
                rethrowIo(e, conn)
            } finally {
                guard.dispose()
                conn.disconnect()
            }
        }

}
