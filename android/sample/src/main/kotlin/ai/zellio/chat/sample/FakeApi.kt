package ai.zellio.chat.sample

import android.content.res.AssetManager
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * A tiny in-process ZeeChat server for the offline demo. It answers the contract v1 endpoints from the shared
 * fixtures (the JSON files in `assets/fixtures`, copied from `sdks/contract/v1/fixtures` at build time), keeps messages in
 * memory, echoes a sent message back over the event stream and sends a canned reply.
 */
class FakeApi(private val assets: AssetManager) {
    private val prefix = "/api/v1/zeechat/mobile"
    private val pool = Executors.newCachedThreadPool()
    private val scheduler = Executors.newSingleThreadScheduledExecutor()
    private val streams = CopyOnWriteArrayList<LinkedBlockingQueue<String>>()
    private val counter = AtomicInteger(10)

    @Volatile
    private var server: ServerSocket? = null

    @Volatile
    var down: Boolean = false

    private val lock = Any()
    private val messages = HashMap<String, JSONArray>()
    private val conversations = ArrayList<JSONObject>()
    private val files = HashMap<String, Pair<String, ByteArray>>()
    private val uploads = HashMap<String, JSONObject>()
    private var identified = false

    val port: Int get() = server?.localPort ?: 0

    private fun fixture(name: String): JSONObject =
        JSONObject(assets.open("fixtures/$name.json").bufferedReader().use { it.readText() }).getJSONObject("data")

    fun start(): Int {
        server?.let { return it.localPort }
        reset()
        val socket = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        server = socket
        pool.execute {
            while (!socket.isClosed) {
                try {
                    val client = socket.accept()
                    pool.execute { handle(client) }
                } catch (_: Exception) {
                    break
                }
            }
        }
        return socket.localPort
    }

    fun stop() {
        server?.close()
        server = null
        streams.clear()
    }

    private fun reset() = synchronized(lock) {
        messages.clear()
        conversations.clear()
        val list = fixture("conversations").getJSONArray("conversations")
        for (i in 0 until list.length()) conversations.add(list.getJSONObject(i))
        val thread = fixture("messages")
        messages["conv_2"] = thread.getJSONArray("messages")
        messages["conv_1"] = JSONArray().put(
            JSONObject()
                .put("id", "msg_0").put("clientMessageId", JSONObject.NULL).put("from", "visitor").put("text", "")
                .put("attachments", JSONArray().put(JSONObject().put("kind", "file").put("url", "https://cdn.example/invoice.pdf").put("name", "invoice.pdf").put("mimeType", "application/pdf").put("size", 90210)))
                .put("createdAt", "2026-10-20T08:30:00.000Z").put("agentName", JSONObject.NULL).put("agentAvatarUrl", JSONObject.NULL),
        )
        identified = false
    }

    // ---- HTTP ----

    private class Request(val method: String, val path: String, val query: Map<String, String>, val headers: Map<String, String>, val body: ByteArray)

    private fun readLine(input: InputStream): String? {
        val out = ByteArrayOutputStream()
        while (true) {
            val b = input.read()
            if (b < 0) return if (out.size() == 0) null else out.toString("UTF-8")
            if (b == '\n'.code) return out.toString("UTF-8").trimEnd('\r')
            out.write(b)
        }
    }

    private fun readRequest(input: InputStream): Request? {
        val first = readLine(input) ?: return null
        val parts = first.split(' ')
        if (parts.size < 2) return null
        val headers = HashMap<String, String>()
        while (true) {
            val line = readLine(input) ?: return null
            if (line.isEmpty()) break
            val i = line.indexOf(':')
            if (i > 0) headers[line.substring(0, i).trim().lowercase()] = line.substring(i + 1).trim()
        }
        val length = headers["content-length"]?.toIntOrNull() ?: 0
        val body = ByteArray(length)
        var read = 0
        while (read < length) {
            val n = input.read(body, read, length - read)
            if (n < 0) break
            read += n
        }
        val target = parts[1]
        val q = target.indexOf('?')
        val path = if (q >= 0) target.substring(0, q) else target
        val query = HashMap<String, String>()
        if (q >= 0) target.substring(q + 1).split('&').forEach { kv ->
            val k = kv.substringBefore('=')
            if (k.isNotEmpty()) query[k] = java.net.URLDecoder.decode(kv.substringAfter('=', ""), "UTF-8")
        }
        return Request(parts[0], path, query, headers, body)
    }

    private fun write(out: OutputStream, status: Int, type: String, body: ByteArray, extra: String = "") {
        val reason = when (status) { 200 -> "OK"; 201 -> "Created"; 202 -> "Accepted"; 401 -> "Unauthorized"; 404 -> "Not Found"; else -> "Error" }
        out.write("HTTP/1.1 $status $reason\r\nContent-Type: $type\r\nContent-Length: ${body.size}\r\nConnection: close\r\n$extra\r\n".toByteArray())
        out.write(body)
        out.flush()
    }

    private fun json(out: OutputStream, status: Int, data: Any) {
        write(out, status, "application/json; charset=utf-8", JSONObject().put("data", data).toString().toByteArray())
    }

    private fun error(out: OutputStream, status: Int, code: String) {
        write(out, status, "application/json; charset=utf-8", JSONObject().put("code", code).put("message", code).toString().toByteArray())
    }

    private fun handle(client: Socket) {
        client.use { socket ->
            try {
                val input = BufferedInputStream(socket.getInputStream())
                val out = socket.getOutputStream()
                val req = readRequest(input) ?: return
                if (down && req.path.endsWith("/config").not() && req.path.startsWith("/files").not()) return // like a dropped network
                route(req, out, socket)
            } catch (_: Exception) {
                // a closed client is normal
            }
        }
    }

    private fun route(req: Request, out: OutputStream, socket: Socket) {
        if (req.path.startsWith("/files/")) {
            val file = synchronized(lock) { files[req.path.removePrefix("/files/")] }
            if (file == null) error(out, 404, "NOT_FOUND") else write(out, 200, file.first, file.second)
            return
        }
        if (!req.path.startsWith(prefix)) return error(out, 404, "NOT_FOUND")
        val path = req.path.removePrefix(prefix)
        if (path == "/config") return write(out, 200, "application/json", JSONObject().put("data", fixture("config")).toString().toByteArray())
        if (path == "/session" && req.method == "POST") {
            val body = JSONObject(String(req.body).ifBlank { "{}" })
            identified = body.optString("identityToken").isNotBlank()
            return json(out, 201, session())
        }
        if (req.headers["x-zee-session-token"] != "tok_demo") return error(out, 401, "CHAT_SESSION_REQUIRED")
        when {
            path == "/session/identify" -> {
                identified = true
                json(out, 200, session())
            }
            path == "/session/logout" -> {
                identified = false
                json(out, 200, JSONObject().put("loggedOut", true))
            }
            path == "/conversations" -> json(out, 200, conversationsBody())
            path.startsWith("/conversations/") && path.endsWith("/messages") -> {
                val id = path.removePrefix("/conversations/").removeSuffix("/messages")
                json(out, 200, thread(id, req.query))
            }
            path == "/messages" && req.method == "POST" -> send(out, JSONObject(String(req.body)))
            path == "/attachments" -> upload(out, req)
            path == "/read" -> {
                val body = JSONObject(String(req.body))
                synchronized(lock) { conversations.firstOrNull { it.getString("id") == body.optString("conversationId") }?.put("unread", 0) }
                json(out, 200, JSONObject().put("unreadTotal", unreadTotal()))
            }
            path == "/unread" -> json(out, 200, JSONObject().put("unreadTotal", unreadTotal()))
            path == "/device" -> json(out, 200, JSONObject().put("registered", req.method == "PUT"))
            path == "/events" -> events(out, socket)
            else -> error(out, 404, "NOT_FOUND")
        }
    }

    private fun session(): JSONObject {
        val base = fixture("session")
        base.put("customer", JSONObject().put("identified", identified).put("name", if (identified) "Mona Adel" else JSONObject.NULL))
        base.put("sessionToken", "tok_demo")
        return base
    }

    private fun unreadTotal(): Int = synchronized(lock) { conversations.sumOf { it.optInt("unread") } }

    private fun conversationsBody(): JSONObject = synchronized(lock) {
        JSONObject().put("conversations", JSONArray(conversations.map { JSONObject(it.toString()) })).put("nextCursor", JSONObject.NULL).put("unreadTotal", unreadTotal())
    }

    private fun thread(id: String, query: Map<String, String>): JSONObject = synchronized(lock) {
        val all = messages[id] ?: JSONArray()
        val after = query["after"]
        val out = JSONArray()
        val from = when {
            query["before"] != null -> all.length() // the whole thread is in the first page
            after != null -> after.removePrefix("i").toIntOrNull() ?: all.length()
            else -> 0
        }
        for (i in from until all.length()) out.put(all.getJSONObject(i))
        JSONObject().put("conversationId", id).put("messages", out).put("nextBefore", JSONObject.NULL).put("latest", "i${all.length()}")
    }

    private fun now(): String {
        val f = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", java.util.Locale.US)
        f.timeZone = java.util.TimeZone.getTimeZone("UTC")
        return f.format(java.util.Date())
    }

    private fun send(out: OutputStream, body: JSONObject) {
        val convId = "conv_2"
        val clientId = body.optString("clientMessageId")
        val ids = body.optJSONArray("attachmentIds") ?: JSONArray()
        val attachments = JSONArray()
        synchronized(lock) {
            for (i in 0 until ids.length()) uploads[ids.getString(i)]?.let { attachments.put(it) }
        }
        val message = JSONObject()
            .put("id", "msg_${counter.incrementAndGet()}").put("clientMessageId", clientId).put("from", "visitor")
            .put("text", body.optString("text")).put("attachments", attachments).put("createdAt", now())
            .put("agentName", JSONObject.NULL).put("agentAvatarUrl", JSONObject.NULL)
        val duplicate = synchronized(lock) {
            val list = messages.getOrPut(convId) { JSONArray() }
            val exists = (0 until list.length()).any { list.getJSONObject(it).optString("clientMessageId") == clientId }
            if (!exists) {
                list.put(message)
                conversations.firstOrNull { it.getString("id") == convId }?.put(
                    "lastMessage", JSONObject().put("from", "visitor").put("text", body.optString("text")).put("hasAttachment", attachments.length() > 0),
                )
            }
            exists
        }
        json(out, 202, JSONObject().put("clientMessageId", clientId).put("accepted", true).put("conversationId", convId))
        if (duplicate) return
        scheduler.schedule({ push("message", message.toString()) }, 150, TimeUnit.MILLISECONDS)
        scheduler.schedule({ push("typing", """{"active":true,"agentName":"Mona"}""") }, 900, TimeUnit.MILLISECONDS)
        scheduler.schedule({ reply(convId) }, 2600, TimeUnit.MILLISECONDS)
    }

    private fun reply(convId: String) {
        val text = "Thanks! I am checking this for you now."
        val reply = JSONObject()
            .put("id", "msg_${counter.incrementAndGet()}").put("clientMessageId", JSONObject.NULL).put("from", "agent").put("text", text)
            .put("attachments", JSONArray()).put("createdAt", now()).put("agentName", "Mona").put("agentAvatarUrl", JSONObject.NULL)
        synchronized(lock) {
            messages.getOrPut(convId) { JSONArray() }.put(reply)
            conversations.firstOrNull { it.getString("id") == convId }?.apply {
                put("lastMessage", JSONObject().put("from", "agent").put("text", text).put("hasAttachment", false))
                put("unread", optInt("unread") + 1)
            }
        }
        push("typing", """{"active":false,"agentName":"Mona"}""")
        push("message", reply.toString())
        push("unread", """{"unreadTotal":${unreadTotal()}}""")
    }

    private fun upload(out: OutputStream, req: Request) {
        val raw = req.body
        val text = String(raw, Charsets.ISO_8859_1)
        val headerEnd = text.indexOf("\r\n\r\n")
        val head = if (headerEnd > 0) text.substring(0, headerEnd) else ""
        val name = Regex("filename=\"([^\"]*)\"").find(head)?.groupValues?.get(1) ?: "file"
        val mime = Regex("Content-Type:\\s*([^\\r\\n]+)", RegexOption.IGNORE_CASE).findAll(head).lastOrNull()?.groupValues?.get(1)?.trim() ?: "application/octet-stream"
        val boundary = req.headers["content-type"]?.substringAfter("boundary=", "")?.trim('"').orEmpty()
        val start = headerEnd + 4
        val endMark = "\r\n--$boundary"
        val end = text.indexOf(endMark, start).let { if (it < 0) raw.size else it }
        val bytes = raw.copyOfRange(start.coerceAtLeast(0), end.coerceAtLeast(start.coerceAtLeast(0)))
        val id = "att_${counter.incrementAndGet()}"
        val attachment = JSONObject()
            .put("kind", if (mime.startsWith("image/")) "image" else "file").put("url", "http://127.0.0.1:$port/files/$id")
            .put("name", name).put("mimeType", mime).put("size", bytes.size)
        synchronized(lock) {
            files[id] = mime to bytes
            uploads[id] = attachment
        }
        Thread.sleep(900) // so the progress ring is visible on a local connection
        json(out, 201, JSONObject(attachment.toString()).put("id", id).put("expiresAt", "2026-12-03T10:00:00.000Z"))
    }

    private fun events(out: OutputStream, socket: Socket) {
        out.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".toByteArray())
        out.write("event: ready\ndata: {\"conversationId\":\"conv_2\"}\n\n".toByteArray())
        out.write("event: agent_joined\ndata: {\"agentName\":\"Mona\",\"agentAvatarUrl\":null}\n\n".toByteArray())
        out.flush()
        val queue = LinkedBlockingQueue<String>()
        streams.add(queue)
        try {
            while (!socket.isClosed && server != null) {
                val next = queue.poll(20, TimeUnit.SECONDS)
                out.write((next ?: ": ping\n\n").toByteArray())
                out.flush()
            }
        } finally {
            streams.remove(queue)
        }
    }

    private fun push(event: String, data: String) {
        val frame = "event: $event\ndata: ${data.replace("\n", " ")}\n\n"
        streams.forEach { it.offer(frame) }
    }

    /** Sends a reply as if an agent wrote it (the "Agent reply" button of the sample). */
    fun agentSays(text: String) {
        val convId = "conv_2"
        val reply = JSONObject()
            .put("id", "msg_${counter.incrementAndGet()}").put("clientMessageId", JSONObject.NULL).put("from", "agent").put("text", text)
            .put("attachments", JSONArray()).put("createdAt", now()).put("agentName", "Mona").put("agentAvatarUrl", JSONObject.NULL)
        synchronized(lock) {
            messages.getOrPut(convId) { JSONArray() }.put(reply)
            conversations.firstOrNull { it.getString("id") == convId }?.apply {
                put("lastMessage", JSONObject().put("from", "agent").put("text", text).put("hasAttachment", false))
                put("unread", optInt("unread") + 1)
            }
        }
        push("message", reply.toString())
        push("unread", """{"unreadTotal":${unreadTotal()}}""")
    }
}
