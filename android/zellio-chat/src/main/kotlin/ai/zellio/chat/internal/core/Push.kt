package ai.zellio.chat.internal.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive

/** The `zellio` key of a push payload (see the contract). Every field can be missing. */
internal data class PushPayload(
    val version: Int?,
    val type: String?,
    val conversationId: String?,
    val messageId: String?,
)

internal object PushParser {
    private const val KEY = "zellio"

    /** True only if the payload has the `zellio` key. The value is not checked. */
    internal fun isOurs(payload: Map<String, *>?): Boolean = payload != null && payload.containsKey(KEY)

    /** [payload] is the FCM data map (the value is a JSON string) or an APNs-style map (the value is a map). */
    internal fun parse(payload: Map<String, *>?): PushPayload? {
        val raw = payload?.get(KEY) ?: return null
        return when (raw) {
            is String -> fromJsonObject(raw)
            is Map<*, *> -> PushPayload(
                version = (raw["v"] as? Number)?.toInt() ?: (raw["v"] as? String)?.toIntOrNull(),
                type = raw["type"]?.toString(),
                conversationId = raw["conversationId"]?.toString(),
                messageId = raw["messageId"]?.toString(),
            )
            else -> null
        }
    }

    /** The whole data payload as JSON text (used by the React Native and Flutter wrappers). */
    internal fun toMap(json: String): Map<String, Any?>? = try {
        (ChatJson.parseToJsonElement(json) as? JsonObject)?.mapValues { (_, v) ->
            if (v is JsonPrimitive) v.contentOrNull else v.toString()
        }
    } catch (_: Exception) {
        null
    }

    private fun fromJsonObject(text: String): PushPayload? = try {
        val obj = ChatJson.parseToJsonElement(text) as? JsonObject
        obj?.let {
            PushPayload(
                version = it["v"]?.jsonPrimitive?.intOrNull,
                type = it["type"]?.jsonPrimitive?.contentOrNull,
                conversationId = it["conversationId"]?.jsonPrimitive?.contentOrNull,
                messageId = it["messageId"]?.jsonPrimitive?.contentOrNull,
            )
        }
    } catch (_: Exception) {
        null
    }
}
