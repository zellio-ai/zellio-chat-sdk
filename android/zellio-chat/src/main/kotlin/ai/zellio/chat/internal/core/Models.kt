package ai.zellio.chat.internal.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement

/** Readers ignore unknown fields. Per-item decoding below skips bad items instead of failing a page. */
internal val ChatJson: Json = Json {
    ignoreUnknownKeys = true
    isLenient = true
    coerceInputValues = true
    explicitNulls = false
    encodeDefaults = true
}

internal enum class ChatLocale(internal val tag: String) {
    AR("ar"),
    EN("en"),
    ;

    internal val rtl: Boolean get() = this == AR

    internal companion object {
        internal fun fromTag(tag: String?): ChatLocale? = when (tag?.trim()?.lowercase()?.split('-', '_')?.firstOrNull()) {
            "ar" -> AR
            "en" -> EN
            else -> null
        }
    }
}

@Serializable
internal data class LocalizedText(val ar: String? = null, val en: String? = null) {
    /** The chat language first, then the other one when it is empty. */
    internal fun pick(locale: ChatLocale): String? {
        val first = if (locale == ChatLocale.AR) ar else en
        val second = if (locale == ChatLocale.AR) en else ar
        return first?.takeIf { it.isNotBlank() } ?: second?.takeIf { it.isNotBlank() }
    }
}

// ---- config ----

@Serializable
internal data class ConfigData(
    val protocol: String? = null,
    val snapshot: Snapshot? = null,
    val assets: Assets = Assets(),
    val availability: Availability = Availability(),
    val app: AppInfo = AppInfo(),
)

@Serializable
internal data class Assets(val logoUrl: String? = null)

@Serializable
internal data class Availability(val online: Boolean = true)

@Serializable
internal data class AppInfo(
    val allowGuests: Boolean = true,
    val minSdkVersion: String? = null,
)

@Serializable
internal data class LanguagePolicy(
    val mode: String = "both",
    val locale: String? = null,
    val defaultLocale: String? = null,
    val startIn: String? = null,
)

@Serializable
internal data class Appearance(
    val brandName: String = "",
    val logoAlt: LocalizedText = LocalizedText(),
    val primaryColor: String = "#7D3BED",
    val customerMessageColor: String = "#7D3BED",
    val surfaceColor: String = "#FFFFFF",
    val theme: String = "auto",
    val density: String = "comfortable",
    val corners: String = "rounded",
    val showAgentAvatar: Boolean = true,
    val soundEnabled: Boolean = false,
    val showAttribution: Boolean = true,
    val headerStyle: String = "gradient",
)

@Serializable
internal data class Screens(
    val heading: LocalizedText = LocalizedText(),
    val greeting: LocalizedText = LocalizedText(),
    val description: LocalizedText = LocalizedText(),
    val offline: LocalizedText = LocalizedText(),
)

@Serializable
internal data class Behavior(
    val allowAttachments: Boolean = true,
    val replyExpectation: LocalizedText = LocalizedText(),
    val consentRequired: Boolean = false,
    val consentText: LocalizedText = LocalizedText(),
    val privacyUrl: String = "",
) {
    internal val consentTerms: ConsentTerms
        get() = ConsentTerms(consentText.en.orEmpty().trim(), consentText.ar.orEmpty().trim(), privacyUrl.trim())
}

/** What a customer accepts: the consent text and the privacy link, not the rest of the published config. */
@Serializable
internal data class ConsentTerms(val en: String, val ar: String, val privacyUrl: String)

@Serializable
internal data class Snapshot(
    val siteId: String = "",
    val versionId: String = "",
    val layout: String = "support",
    val language: LanguagePolicy = LanguagePolicy(),
    val appearance: Appearance = Appearance(),
    val modules: JsonArray = JsonArray(emptyList()),
    val screens: Screens = Screens(),
    val behavior: Behavior = Behavior(),
)

@Serializable
internal data class Visibility(
    val locales: List<String>? = null,
    val availability: String? = null,
    val customer: String? = null,
)

@Serializable
internal data class LinkDto(val label: LocalizedText = LocalizedText(), val href: String? = null)

@Serializable
internal data class ModuleDto(
    val id: String = "",
    val type: String = "",
    val label: LocalizedText = LocalizedText(),
    val description: LocalizedText = LocalizedText(),
    val href: String? = null,
    val primary: Boolean = false,
    val links: JsonArray = JsonArray(emptyList()),
    val visibility: Visibility = Visibility(),
    val disabled: Boolean = false,
)

internal data class ContactLink(val label: LocalizedText, val href: String)

internal sealed interface HomeModule {
    val id: String
    val visibility: Visibility

    data class Greeting(override val id: String, val label: LocalizedText, val description: LocalizedText, override val visibility: Visibility) : HomeModule
    data class Announcement(override val id: String, val label: LocalizedText, val description: LocalizedText, override val visibility: Visibility) : HomeModule
    data class StartConversation(override val id: String, val label: LocalizedText, val primary: Boolean, override val visibility: Visibility) : HomeModule
    data class ExternalLink(override val id: String, val label: LocalizedText, val href: String, override val visibility: Visibility) : HomeModule
    data class ContactLinks(override val id: String, val label: LocalizedText, val links: List<ContactLink>, override val visibility: Visibility) : HomeModule
}

// ---- session ----

@Serializable
internal data class CustomerDto(val identified: Boolean = false, val name: String? = null)

@Serializable
internal data class SessionData(
    val sessionToken: String = "",
    val expiresAt: String? = null,
    val customer: CustomerDto = CustomerDto(),
    val versionId: String? = null,
)

@Serializable
internal data class SessionRequest(
    val installId: String,
    val platform: String,
    val locale: String,
    val identityToken: String? = null,
)

@Serializable
internal data class IdentifyRequest(val identityToken: String)

// ---- conversations ----

@Serializable
internal data class LastMessageDto(
    val from: String? = null,
    val text: String? = null,
    val hasAttachment: Boolean = false,
    val attachmentKind: String? = null,
)

@Serializable
internal data class ConversationDto(
    val id: String = "",
    val status: String? = null,
    val lastMessageAt: String? = null,
    val lastMessage: LastMessageDto? = null,
    val agentName: String? = null,
    val agentAvatarUrl: String? = null,
    val unread: Int = 0,
)

@Serializable
internal data class ConversationsData(
    val conversations: JsonArray = JsonArray(emptyList()),
    val nextCursor: String? = null,
    val unreadTotal: Int = 0,
)

@Serializable
internal data class ConversationSummary(
    val id: String,
    val status: String?,
    val lastMessageAtMs: Long,
    val lastText: String,
    val lastHasAttachment: Boolean,
    val lastAttachmentKind: String?,
    val lastFromVisitor: Boolean,
    val agentName: String?,
    val agentAvatarUrl: String?,
    val unread: Int,
)

internal data class ConversationsPage(val items: List<ConversationSummary>, val nextCursor: String?, val unreadTotal: Int)

// ---- messages ----

internal enum class Sender { VISITOR, AGENT }

@Serializable
internal data class AttachmentDto(
    val id: String? = null,
    val kind: String? = null,
    val url: String? = null,
    val name: String? = null,
    val mimeType: String? = null,
    val size: Long? = null,
)

@Serializable
internal data class MessageDto(
    val id: String = "",
    val clientMessageId: String? = null,
    val from: String = "",
    val text: String? = null,
    val attachments: JsonArray = JsonArray(emptyList()),
    val createdAt: String? = null,
    val agentName: String? = null,
    val agentAvatarUrl: String? = null,
    val conversationId: String? = null,
)

@Serializable
internal data class MessagesData(
    val conversationId: String? = null,
    val messages: JsonArray = JsonArray(emptyList()),
    val nextBefore: String? = null,
    val latest: String? = null,
)

@Serializable
internal data class Attachment(
    val kind: String,
    val url: String,
    val name: String,
    val mimeType: String,
    val size: Long,
) {
    internal val isImage: Boolean get() = kind == "image" || mimeType.startsWith("image/")
}

@Serializable
internal data class ChatMessage(
    val id: String,
    val clientMessageId: String?,
    val fromVisitor: Boolean,
    val text: String,
    val attachments: List<Attachment>,
    val createdAtMs: Long,
    val agentName: String?,
    val agentAvatarUrl: String?,
) {
    /** Stable list key: survives the swap from a local message to the server copy. */
    internal val key: String get() = clientMessageId ?: id
}

internal data class MessagesPage(
    val conversationId: String?,
    val messages: List<ChatMessage>,
    val nextBefore: String?,
    val latest: String?,
)

// ---- other requests ----

@Serializable
internal data class ChatContext(
    val screen: String? = null,
    val itemType: String? = null,
    val itemId: String? = null,
    val itemTitle: String? = null,
    val url: String? = null,
)

@Serializable
internal data class SendRequest(
    val text: String,
    val clientMessageId: String,
    val attachmentIds: List<String> = emptyList(),
    val context: ChatContext? = null,
)

@Serializable
internal data class SendResult(
    val clientMessageId: String? = null,
    val accepted: Boolean = true,
    val conversationId: String? = null,
)

@Serializable
internal data class UploadedAttachment(
    val id: String = "",
    val kind: String? = null,
    val name: String? = null,
    val mimeType: String? = null,
    val size: Long? = null,
    val url: String? = null,
    val expiresAt: String? = null,
)

@Serializable
internal data class ReadRequest(val conversationId: String, val upTo: String)

@Serializable
internal data class UnreadData(val unreadTotal: Int = 0)

@Serializable
internal data class DeviceRequest(
    val provider: String,
    val pushToken: String,
    val environment: String? = null,
    val locale: String,
    val appVersion: String? = null,
)

// ---- decoding, item by item ----

internal object Decoders {
    private inline fun <reified T> item(element: JsonElement): T? =
        try {
            if (element is JsonObject) ChatJson.decodeFromJsonElement<T>(element) else null
        } catch (_: Exception) {
            null
        }

    internal fun modules(array: JsonArray): List<HomeModule> = array.mapNotNull { el ->
        val dto = item<ModuleDto>(el) ?: return@mapNotNull null
        if (dto.disabled || dto.id.isBlank()) return@mapNotNull null
        when (dto.type) {
            "greeting" -> HomeModule.Greeting(dto.id, dto.label, dto.description, dto.visibility)
            "announcement" -> HomeModule.Announcement(dto.id, dto.label, dto.description, dto.visibility)
            "start-conversation" -> HomeModule.StartConversation(dto.id, dto.label, dto.primary, dto.visibility)
            "external-link" -> dto.href?.takeIf { LinkPolicy.isSafe(it) }
                ?.let { HomeModule.ExternalLink(dto.id, dto.label, it, dto.visibility) }
            "contact-links" -> {
                val links = dto.links.mapNotNull { l ->
                    val link = item<LinkDto>(l) ?: return@mapNotNull null
                    val href = link.href?.takeIf { LinkPolicy.isSafe(it) } ?: return@mapNotNull null
                    ContactLink(link.label, href)
                }
                HomeModule.ContactLinks(dto.id, dto.label, links, dto.visibility)
            }
            else -> null // unknown module: skipped, never a crash
        }
    }

    internal fun conversations(data: ConversationsData): ConversationsPage {
        val items = data.conversations.mapNotNull { el ->
            val dto = item<ConversationDto>(el) ?: return@mapNotNull null
            if (dto.id.isBlank()) return@mapNotNull null
            ConversationSummary(
                id = dto.id,
                status = dto.status,
                lastMessageAtMs = IsoTime.parse(dto.lastMessageAt) ?: 0L,
                lastText = dto.lastMessage?.text.orEmpty(),
                lastHasAttachment = dto.lastMessage?.hasAttachment ?: false,
                lastAttachmentKind = dto.lastMessage?.attachmentKind,
                lastFromVisitor = dto.lastMessage?.from == "visitor",
                agentName = dto.agentName,
                agentAvatarUrl = dto.agentAvatarUrl,
                unread = dto.unread,
            )
        }
        return ConversationsPage(items, data.nextCursor, data.unreadTotal)
    }

    internal fun message(el: JsonElement): ChatMessage? {
        val dto = item<MessageDto>(el) ?: return null
        return message(dto)
    }

    internal fun message(dto: MessageDto): ChatMessage? {
        if (dto.id.isBlank()) return null
        val fromVisitor = when (dto.from) {
            "visitor" -> true
            "agent" -> false
            else -> return null // unknown sender: skipped
        }
        val createdAt = IsoTime.parse(dto.createdAt) ?: return null
        val attachments = dto.attachments.mapNotNull { a ->
            val att = item<AttachmentDto>(a) ?: return@mapNotNull null
            val url = att.url?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            Attachment(
                kind = att.kind ?: if (att.mimeType?.startsWith("image/") == true) "image" else "file",
                url = url,
                name = att.name.orEmpty(),
                mimeType = att.mimeType.orEmpty(),
                size = att.size ?: 0L,
            )
        }
        return ChatMessage(
            id = dto.id,
            clientMessageId = dto.clientMessageId?.takeIf { it.isNotBlank() },
            fromVisitor = fromVisitor,
            text = dto.text.orEmpty(),
            attachments = attachments,
            createdAtMs = createdAt,
            agentName = dto.agentName,
            agentAvatarUrl = dto.agentAvatarUrl,
        )
    }

    internal fun messages(data: MessagesData): MessagesPage =
        MessagesPage(data.conversationId, data.messages.mapNotNull { message(it) }, data.nextBefore, data.latest)
}

/** Links: only https, mailto and tel, and never with embedded credentials. */
internal object LinkPolicy {
    internal fun isSafe(value: String): Boolean {
        if (value.length > 2000) return false
        val lower = value.trim().lowercase()
        if (lower.startsWith("mailto:") || lower.startsWith("tel:")) return lower.length > 7
        if (!lower.startsWith("https://")) return false
        val authority = lower.removePrefix("https://").substringBefore('/').substringBefore('?').substringBefore('#')
        return authority.isNotEmpty() && '@' !in authority
    }
}
