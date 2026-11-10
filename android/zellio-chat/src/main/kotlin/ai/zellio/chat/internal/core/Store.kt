package ai.zellio.chat.internal.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import java.io.File
import java.util.UUID

/** Small named-string storage. Implementations must survive a process kill between calls. */
internal interface KeyValueStore {
    fun read(name: String): String?
    fun write(name: String, value: String)
    fun delete(name: String)
    fun deleteAll()
}

/** Atomic file store (write to a temp file, then rename). The directory is excluded from backups. */
internal class FileStore(private val dir: File) : KeyValueStore {
    private fun file(name: String) = File(dir, name.replace(Regex("[^A-Za-z0-9._-]"), "_"))

    @Synchronized
    override fun read(name: String): String? = try {
        file(name).takeIf { it.isFile }?.readText(Charsets.UTF_8)
    } catch (_: Exception) {
        null
    }

    @Synchronized
    override fun write(name: String, value: String) {
        dir.mkdirs()
        val target = file(name)
        val tmp = File(dir, target.name + ".tmp")
        tmp.writeText(value, Charsets.UTF_8)
        if (!tmp.renameTo(target)) {
            target.delete()
            check(tmp.renameTo(target)) { "rename failed" }
        }
    }

    @Synchronized
    override fun delete(name: String) {
        file(name).delete()
    }

    @Synchronized
    override fun deleteAll() {
        dir.deleteRecursively()
    }
}

internal class MemoryStore : KeyValueStore {
    private val map = java.util.concurrent.ConcurrentHashMap<String, String>()
    override fun read(name: String): String? = map[name]
    override fun write(name: String, value: String) {
        map[name] = value
    }

    override fun delete(name: String) {
        map.remove(name)
    }

    override fun deleteAll() = map.clear()
}

/** Holds the secret session record. On Android it is Keystore-backed AES-GCM. */
internal interface SecretVault {
    fun load(): String?
    fun save(value: String)
    fun clear()
}

internal class MemoryVault : SecretVault {
    @Volatile
    private var value: String? = null
    override fun load(): String? = value
    override fun save(value: String) {
        this.value = value
    }

    override fun clear() {
        value = null
    }
}

@Serializable
internal data class SessionRecord(
    val token: String,
    val identified: Boolean,
    val name: String? = null,
    /** The brand's user id (`sub`) this session belongs to. Null for a guest. */
    val sub: String? = null,
)

@Serializable
internal data class ThreadCache(val messages: List<ChatMessage>)

/** Typed access to everything the SDK keeps on the phone. Logout calls [wipe]. */
internal class LocalData(private val store: KeyValueStore, private val vault: SecretVault) {

    internal fun installId(): String {
        store.read("install-id")?.takeIf { it.isNotBlank() }?.let { return it }
        val id = UUID.randomUUID().toString()
        store.write("install-id", id)
        return id
    }

    internal fun loadConfig(): ConfigData? = decode("config.json", ConfigData.serializer())
    internal fun saveConfig(config: ConfigData) = encode("config.json", ConfigData.serializer(), config)

    internal fun acceptedConsent(): ConsentTerms? = decode("consent.json", ConsentTerms.serializer())
    internal fun saveConsent(terms: ConsentTerms) = encode("consent.json", ConsentTerms.serializer(), terms)

    internal fun loadSession(): SessionRecord? {
        val record = try {
            vault.load()?.let { ChatJson.decodeFromString(SessionRecord.serializer(), it) }
        } catch (_: Exception) {
            null
        } ?: return null
        return record
    }

    internal fun saveSession(record: SessionRecord) = vault.save(ChatJson.encodeToString(SessionRecord.serializer(), record))
    internal fun clearSession() = vault.clear()

    internal fun loadConversations(): List<ConversationSummary> =
        decode("conversations.json", ListSerializer(ConversationSummary.serializer())).orEmpty()

    internal fun saveConversations(items: List<ConversationSummary>) =
        encode("conversations.json", ListSerializer(ConversationSummary.serializer()), items)

    /** Only the newest [MAX_CACHED_MESSAGES] of each conversation are kept. */
    internal fun loadThread(conversationId: String): List<ChatMessage> =
        decode("thread-$conversationId.json", ThreadCache.serializer())?.messages.orEmpty()

    internal fun saveThread(conversationId: String, messages: List<ChatMessage>) =
        encode("thread-$conversationId.json", ThreadCache.serializer(), ThreadCache(messages.takeLast(MAX_CACHED_MESSAGES)))

    internal fun loadDrafts(): Map<String, String> = decode("drafts.json", MapSerializer(String.serializer(), String.serializer())).orEmpty()
    internal fun saveDrafts(drafts: Map<String, String>) = encode("drafts.json", MapSerializer(String.serializer(), String.serializer()), drafts)

    internal fun loadPushToken(): PushRegistration? = decode("push-token.json", PushRegistration.serializer())
    internal fun savePushToken(value: PushRegistration) = encode("push-token.json", PushRegistration.serializer(), value)

    /** Deletes all local chat data. The install id survives: it only resets on reinstall. */
    internal fun wipe() {
        val id = store.read("install-id")
        val push = store.read("push-token.json")
        store.deleteAll()
        vault.clear()
        if (id != null) store.write("install-id", id)
        if (push != null) store.write("push-token.json", push)
    }

    private fun <T> decode(name: String, serializer: kotlinx.serialization.KSerializer<T>): T? = try {
        store.read(name)?.let { ChatJson.decodeFromString(serializer, it) }
    } catch (_: Exception) {
        null
    }

    private fun <T> encode(name: String, serializer: kotlinx.serialization.KSerializer<T>, value: T) {
        try {
            store.write(name, ChatJson.encodeToString(serializer, value))
        } catch (t: Throwable) {
            Guard.report("store $name", t)
        }
    }

    internal companion object {
        internal const val MAX_CACHED_MESSAGES = 200
    }
}

@Serializable
internal data class PushRegistration(val provider: String, val token: String, val environment: String? = null)
