package ai.zellio.chat

import ai.zellio.chat.internal.core.ChatJson
import com.sun.net.httpserver.HttpServer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.jsonObject
import java.io.File
import java.net.InetSocketAddress
import java.util.concurrent.CopyOnWriteArrayList

/** The shared contract fixtures, read straight from `sdks/contract/v1/fixtures`. */
object Fixtures {
    private val dir = File(requireNotNull(System.getProperty("zellio.contract.dir")) { "zellio.contract.dir is not set" })

    fun text(name: String): String = File(dir, "fixtures/$name.json").readText(Charsets.UTF_8)

    /** The `data` object of a fixture. */
    fun data(name: String): JsonElement = ChatJson.parseToJsonElement(text(name)).jsonObject.getValue("data")
}

class Recorded(val method: String, val path: String, val query: String?, val headers: Map<String, String>, val body: String)

class Reply(val status: Int, val body: String, val headers: Map<String, String> = emptyMap(), val contentType: String = "application/json")

/** A local HTTP server for the client tests (JDK `com.sun.net.httpserver`). */
class FakeServer(private val handler: (Recorded) -> Reply) {
    private val server: HttpServer = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
    val requests = CopyOnWriteArrayList<Recorded>()
    val url: String get() = "http://127.0.0.1:${server.address.port}"

    init {
        server.createContext("/") { ex ->
            val headers = ex.requestHeaders.entries.associate { it.key.lowercase() to it.value.joinToString(",") }
            val rec = Recorded(ex.requestMethod, ex.requestURI.path, ex.requestURI.rawQuery, headers, String(ex.requestBody.readBytes(), Charsets.UTF_8))
            requests += rec
            val reply = handler(rec)
            val bytes = reply.body.toByteArray(Charsets.UTF_8)
            ex.responseHeaders.add("Content-Type", reply.contentType)
            reply.headers.forEach { (k, v) -> ex.responseHeaders.add(k, v) }
            ex.sendResponseHeaders(reply.status, if (bytes.isEmpty()) -1 else bytes.size.toLong())
            if (bytes.isNotEmpty()) ex.responseBody.use { it.write(bytes) } else ex.close()
        }
        server.start()
    }

    fun stop() = server.stop(0)
}

fun error(status: Int, code: String, nested: Boolean = false, headers: Map<String, String> = emptyMap()): Reply =
    Reply(status, if (nested) """{"error":{"code":"$code","message":"x"}}""" else """{"code":"$code","message":"x"}""", headers)

fun ok(json: String, status: Int = 200) = Reply(status, """{"data":$json}""")
