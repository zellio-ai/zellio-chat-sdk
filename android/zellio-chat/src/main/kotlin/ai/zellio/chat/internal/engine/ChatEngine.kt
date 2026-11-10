package ai.zellio.chat.internal.engine

import ai.zellio.chat.internal.core.ApiClient
import ai.zellio.chat.internal.core.ApiException
import ai.zellio.chat.internal.core.AppInfo
import ai.zellio.chat.internal.core.Backoff
import ai.zellio.chat.internal.core.DeviceRegistrar
import ai.zellio.chat.internal.core.Blocked
import ai.zellio.chat.internal.core.ChatContext
import ai.zellio.chat.internal.core.ChatErrorCode
import ai.zellio.chat.internal.core.ChatJson
import ai.zellio.chat.internal.core.ChatLocale
import ai.zellio.chat.internal.core.ChatMessage
import ai.zellio.chat.internal.core.Clock
import ai.zellio.chat.internal.core.ConfigData
import ai.zellio.chat.internal.core.ConsentGate
import ai.zellio.chat.internal.core.ConsentTerms
import ai.zellio.chat.internal.core.ConsentRequiredException
import ai.zellio.chat.internal.core.ConversationSummary
import ai.zellio.chat.internal.core.Decoders
import ai.zellio.chat.internal.core.DeviceRequest
import ai.zellio.chat.internal.core.Gate
import ai.zellio.chat.internal.core.Guard
import ai.zellio.chat.internal.core.IdentityProvider
import ai.zellio.chat.internal.core.Jwt
import ai.zellio.chat.internal.core.KeyValueStore
import ai.zellio.chat.internal.core.LocalData
import ai.zellio.chat.internal.core.LocaleChooser
import ai.zellio.chat.internal.core.LocaleOption
import ai.zellio.chat.internal.core.Log
import ai.zellio.chat.internal.core.LoginNeededException
import ai.zellio.chat.internal.core.MessageDto
import ai.zellio.chat.internal.core.MessagesPage
import ai.zellio.chat.internal.core.NetworkException
import ai.zellio.chat.internal.core.Outbox
import ai.zellio.chat.internal.core.OutboxAttachment
import ai.zellio.chat.internal.core.OutboxEntry
import ai.zellio.chat.internal.core.OutboxSender
import ai.zellio.chat.internal.core.Palette
import ai.zellio.chat.internal.core.PublicErrorCode
import ai.zellio.chat.internal.core.PushRegistration
import ai.zellio.chat.internal.core.Reaction
import ai.zellio.chat.internal.core.SecretVault
import ai.zellio.chat.internal.core.SemVer
import ai.zellio.chat.internal.core.SenderListener
import ai.zellio.chat.internal.core.SessionGateway
import ai.zellio.chat.internal.core.SessionHolder
import ai.zellio.chat.internal.core.SessionRecord
import ai.zellio.chat.internal.core.Shapes
import ai.zellio.chat.internal.core.SseEvent
import ai.zellio.chat.internal.core.ThemeOverrides
import ai.zellio.chat.internal.core.ThreadData
import ai.zellio.chat.internal.core.ThreadMerge
import ai.zellio.chat.internal.core.Appearance
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import java.util.UUID

internal enum class HapticKind { SEND, RECEIVE, FAILED }

internal data class BannerInfo(
    val conversationId: String?,
    val name: String,
    val avatarUrl: String?,
    /** Null when previews are off: the banner shows "New message". */
    val preview: String?,
)

/** What the engine needs from the host side (Android): visibility, banner, haptics, listeners. */
private const val MAX_STREAM_RETRY_AFTER_SECONDS = 300L

internal interface EngineHooks {
    fun isForeground(): Boolean
    fun isChatVisible(): Boolean
    fun onMessageSent() {}
    fun onMessageReceived() {}
    fun onError(code: String) {}
    fun showBanner(info: BannerInfo) {}
    fun haptic(kind: HapticKind) {}
    fun playSound() {}

    /** All local chat data was deleted (logout, customer switch): drop caches the engine does not own. */
    fun onWiped() {}
}

internal data class ConversationsState(
    val items: List<ConversationSummary> = emptyList(),
    val loading: Boolean = false,
    val failed: Boolean = false,
)

internal enum class Connection { IDLE, CONNECTED, RECONNECTING }

internal data class Typing(val active: Boolean = false, val agentName: String? = null)

internal data class AgentInfo(val name: String?, val avatarUrl: String?)

/**
 * The brain of the SDK. No Android classes in here: it is driven by [EngineHooks], a [KeyValueStore] and a
 * [SecretVault], so the same code runs on the JVM in tests. One instance per `configure`.
 */
internal class ChatEngine(
    private val appKey: String,
    baseUrl: String,
    private val sdkVersion: String,
    wrapper: String?,
    store: KeyValueStore,
    vault: SecretVault,
    private val clock: Clock,
    internal val scope: CoroutineScope,
    private val localeOption: LocaleOption,
    private val deviceLanguage: () -> String?,
    internal val themeOverrides: ThemeOverrides,
    private val appVersion: String?,
    private val hooks: EngineHooks,
    private val sessionHolder: SessionHolder = SessionHolder(),
) {
    internal val data = LocalData(store, vault)
    internal val outbox = Outbox(store, clock)

    private val installId: String = data.installId()

    @Volatile
    private var identityProvider: IdentityProvider? = null

    private val configFlow = MutableStateFlow<ConfigData?>(null)
    private val configFresh = MutableStateFlow(false)
    private val configFailed = MutableStateFlow(false)
    private val acceptedConsent = MutableStateFlow<ConsentTerms?>(null)
    private val blockedFlow = MutableStateFlow(Blocked.NONE)
    private val sessionFlow = MutableStateFlow<SessionRecord?>(null)
    private val unreadFlow = MutableStateFlow(0)
    private val conversationsFlow = MutableStateFlow(ConversationsState())
    private val connectionFlow = MutableStateFlow(Connection.IDLE)
    private val reconnectBanner = MutableStateFlow(false)
    private val threadsFlow = MutableStateFlow<Map<String, ThreadData>>(emptyMap())
    private val typingFlow = MutableStateFlow(Typing())
    private val agentFlow = MutableStateFlow<Map<String, AgentInfo>>(emptyMap())
    private val progressFlow = MutableStateFlow<Map<String, Float>>(emptyMap())
    private val filesDisabled = MutableStateFlow(false)
    private val rateLimited = MutableStateFlow(false)
    private val contextFlow = MutableStateFlow<ChatContext?>(null)
    private val deviceLanguageFlow = MutableStateFlow(deviceLanguage())
    private val drafts = MutableStateFlow<Map<String, String>>(emptyMap())

    internal val config: StateFlow<ConfigData?> = configFlow.asStateFlow()
    internal val configLoadFailed: StateFlow<Boolean> = configFailed.asStateFlow()
    internal val blocked: StateFlow<Blocked> = blockedFlow.asStateFlow()
    internal val session: StateFlow<SessionRecord?> = sessionFlow.asStateFlow()
    internal val unread: StateFlow<Int> = unreadFlow.asStateFlow()
    internal val conversations: StateFlow<ConversationsState> = conversationsFlow.asStateFlow()
    internal val connection: StateFlow<Connection> = connectionFlow.asStateFlow()

    /** True after the stream was down for 3 seconds. */
    internal val showReconnecting: StateFlow<Boolean> = reconnectBanner.asStateFlow()
    internal val threads: StateFlow<Map<String, ThreadData>> = threadsFlow.asStateFlow()
    internal val typing: StateFlow<Typing> = typingFlow.asStateFlow()
    internal val agents: StateFlow<Map<String, AgentInfo>> = agentFlow.asStateFlow()
    internal val uploadProgress: StateFlow<Map<String, Float>> = progressFlow.asStateFlow()
    internal val attachDisabledByServer: StateFlow<Boolean> = filesDisabled.asStateFlow()
    internal val isRateLimited: StateFlow<Boolean> = rateLimited.asStateFlow()
    internal val acceptedTerms: StateFlow<ConsentTerms?> = acceptedConsent.asStateFlow()
    internal val sendContext: StateFlow<ChatContext?> = contextFlow.asStateFlow()

    private val activeConversationFlow = MutableStateFlow<String?>(null)

    /** The conversation the server last named for this thread. A thread that has not learned its id yet adopts it. */
    internal val activeConversation: StateFlow<String?> = activeConversationFlow.asStateFlow()

    internal var activeConversationId: String?
        get() = activeConversationFlow.value
        private set(value) {
            activeConversationFlow.value = value
        }

    private val api = ApiClient(baseUrl, appKey, sdkVersion, wrapper, sessionHolder::token)

    internal val gateway = SessionGateway(
        api = api,
        holder = sessionHolder,
        data = data,
        installId = installId,
        localeTag = { locale().tag },
        identity = { identityProvider },
        listener = { state ->
            if (blockedFlow.value != state) blockedFlow.value = state
        },
        beforeCreate = { requireCreateAllowed() },
        onSessionSaved = { scope.launch { Guard.run("register device") { registrar.register() } } },
    )

    private val registrar: DeviceRegistrar = DeviceRegistrar(gateway, sessionHolder, { push }, { locale().tag }, appVersion)

    private val sender = OutboxSender(
        outbox, gateway, clock,
        listener = object : SenderListener {
            override fun onAccepted(entry: OutboxEntry, conversationId: String?) {
                hooks.onMessageSent()
                if (conversationId != null) activeConversationId = activeConversationId ?: conversationId
                scope.launch { catchUp() }
            }

            override fun onFailed(entry: OutboxEntry, reason: String) {
                hooks.haptic(HapticKind.FAILED)
                hooks.onError(PublicErrorCode.SEND_FAILED)
                if (reason == ChatErrorCode.FILES_DISABLED.wire) filesDisabled.value = true
            }

            override fun onRateLimited() {
                rateLimited.value = true
                hooks.onError(PublicErrorCode.RATE_LIMITED)
            }

            override fun onProgress(clientMessageId: String, progress: Float?) {
                progressFlow.update { if (progress == null) it - clientMessageId else it + (clientMessageId to progress) }
            }
        },
    )

    private val controllers = HashMap<String, ThreadController>()
    private var streamJob: Job? = null
    private var drainJob: Job? = null
    private var reconnectTimer: Job? = null
    private var typingTimer: Job? = null
    private var readJob: Job? = null
    private var configJob: Job? = null
    private val configMutex = kotlinx.coroutines.sync.Mutex()

    // ---- derived values ----

    internal fun locale(): ChatLocale =
        LocaleChooser.choose(localeOption, configFlow.value?.snapshot?.language, deviceLanguageFlow.value)

    internal fun gate(): Gate = ConsentGate.state(configFlow.value?.snapshot, acceptedConsent.value)

    internal fun appearance(): Appearance = configFlow.value?.snapshot?.appearance ?: Appearance()

    internal fun palette(systemDark: Boolean): Palette = Palette.build(appearance(), themeOverrides, systemDark)

    internal fun shapes(): Shapes = Shapes.of(appearance())

    internal fun attachAllowed(): Boolean = (configFlow.value?.snapshot?.behavior?.allowAttachments ?: true) && !filesDisabled.value

    internal fun appInfo(): AppInfo = configFlow.value?.app ?: AppInfo()

    internal fun draft(key: String): String = drafts.value[key].orEmpty()

    internal fun setDraft(key: String, text: String) {
        drafts.update { if (text.isEmpty()) it - key else it + (key to text) }
        scope.launch { Guard.run("drafts") { data.saveDrafts(drafts.value) } }
    }

    internal fun setContext(context: ChatContext?) {
        contextFlow.value = context
    }

    internal fun onLocaleChanged() {
        deviceLanguageFlow.value = deviceLanguage()
    }

    // ---- start and lifecycle ----

    internal fun start() {
        Guard.run("engine.start") {
            data.loadConfig()?.let { configFlow.value = it }
            acceptedConsent.value = data.acceptedConsent()
            gateway.restore()
            sessionFlow.value = sessionHolder.record
            drafts.value = data.loadDrafts()
            outbox.load()
            conversationsFlow.value = ConversationsState(items = data.loadConversations())
            refreshConfig()
        }
    }

    /** Reads `/config` again. A saved config draws at once; it never starts a session by itself. */
    internal fun refreshConfig() {
        if (configJob?.isActive == true) return
        configJob = scope.launch {
            configMutex.withLock {
                try {
                    val fresh = api.config()
                    configFlow.value = fresh
                    configFresh.value = true
                    configFailed.value = false
                    data.saveConfig(fresh)
                    checkSdkVersion(fresh)
                    reconcile()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: ApiException) {
                    Log.w("config failed: ${e.rawCode ?: e.status}")
                    configFailed.value = configFlow.value == null
                    handleTerminal(e)
                } catch (e: NetworkException) {
                    configFailed.value = configFlow.value == null
                } catch (t: Throwable) {
                    configFailed.value = configFlow.value == null
                    Guard.report("config", t)
                }
            }
        }
    }

    private fun checkSdkVersion(config: ConfigData) {
        val min = config.app.minSdkVersion ?: return
        if (SemVer.compare(sdkVersion, min) < 0) {
            Log.e("SDK $sdkVersion is older than the minimum $min")
            hooks.onError(PublicErrorCode.UNAVAILABLE)
            blockedFlow.value = Blocked.UNAVAILABLE
        }
    }

    internal fun onForeground() {
        Guard.run("foreground") {
            refreshConfig()
            scope.launch { reconcile(); catchUp() }
        }
    }

    internal fun onBackground() {
        Guard.run("background") {
            stopStream()
        }
    }

    /** Waits for the fresh config; fails if there is none. Used before a session may start. */
    private suspend fun requireCreateAllowed() {
        if (!configFresh.value) {
            refreshConfig()
            configJob?.join()
        }
        if (!configFresh.value) throw NetworkException(java.io.IOException("config unavailable"))
        if (gate() != Gate.OPEN) throw ConsentRequiredException()
        if (blockedFlow.value == Blocked.UNAVAILABLE) throw ApiException(403, ChatErrorCode.APP_DISABLED, ChatErrorCode.APP_DISABLED.wire)
    }

    private fun handleTerminal(e: ApiException) {
        when (e.reaction) {
            Reaction.UNAVAILABLE -> {
                blockedFlow.value = Blocked.UNAVAILABLE
                hooks.onError(PublicErrorCode.UNAVAILABLE)
                stopStream()
            }
            Reaction.LOGIN_NEEDED -> blockedFlow.value = Blocked.LOGIN_NEEDED
            else -> Unit
        }
    }

    // ---- consent ----

    internal fun acceptConsent() {
        val terms = configFlow.value?.snapshot?.behavior?.consentTerms ?: return
        acceptedConsent.value = terms
        scope.launch {
            Guard.run("consent") { data.saveConsent(terms) }
            reconcile()
            catchUp()
        }
    }

    // ---- identity ----

    internal fun identify(provider: IdentityProvider) {
        identityProvider = provider
        blockedFlow.update { if (it == Blocked.LOGIN_NEEDED) Blocked.NONE else it }
        scope.launch { reconcile(explicit = true) }
    }

    /**
     * Brings the session in line with the identity: a different customer logs the old one out first, a guest session
     * becomes a customer session. Only runs when the consent gate is open.
     */
    private val reconcileMutex = kotlinx.coroutines.sync.Mutex()

    private suspend fun reconcile(explicit: Boolean = false) {
        reconcileMutex.lock()
        try {
            val provider = identityProvider
            if (gate() != Gate.OPEN || blockedFlow.value == Blocked.UNAVAILABLE) return
            if (provider == null) {
                if (sessionHolder.record != null) startStream()
                return
            }
            val record = sessionHolder.record
            try {
                if (record == null) {
                    if (!configFresh.value) return
                    gateway.ensureSession()
                } else if (explicit || !record.identified) {
                    val token = try { provider() } catch (e: CancellationException) { throw e } catch (t: Throwable) { Guard.report("token provider", t); null }
                    if (token.isNullOrBlank()) {
                        blockedFlow.value = Blocked.LOGIN_NEEDED
                        return
                    }
                    val sub = Jwt.subject(token)
                    if (record.sub != null && sub != null && record.sub != sub) {
                        // A new customer: the old one is logged out first, then a session starts for the new one.
                        wipeEverything(callServer = true)
                        gateway.ensureSession()
                    } else if (!record.identified) {
                        var first: String? = token
                        gateway.identify { first?.also { first = null } ?: provider() }
                    }
                }
                sessionFlow.value = sessionHolder.record
                registerDevice()
                startStream()
                drainOutbox()
            } catch (e: CancellationException) {
                throw e
            } catch (e: LoginNeededException) {
                blockedFlow.value = Blocked.LOGIN_NEEDED
            } catch (e: ConsentRequiredException) {
                // waiting for Accept
            } catch (e: NetworkException) {
                // offline: the next foreground or retry tries again
            } catch (e: ApiException) {
                handleTerminal(e)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            Guard.report("reconcile", t)
        } finally {
            reconcileMutex.unlock()
        }
    }

    /** Called when the customer opens a screen that needs a session. */
    internal suspend fun ensureSession(): Boolean = try {
        if (gate() != Gate.OPEN) false
        else {
            gateway.ensureSession()
            sessionFlow.value = sessionHolder.record
            registerDevice()
            startStream()
            true
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: ApiException) {
        handleTerminal(e)
        false
    } catch (e: LoginNeededException) {
        blockedFlow.value = Blocked.LOGIN_NEEDED
        false
    } catch (_: ConsentRequiredException) {
        false
    } catch (_: NetworkException) {
        false
    } catch (t: Throwable) {
        Guard.report("ensureSession", t)
        false
    }

    internal fun logout() {
        identityProvider = null
        scope.launch {
            Guard.run("logout") {
                try {
                    wipeEverything(callServer = true)
                } finally {
                    refreshConfig()
                }
            }
        }
    }

    private suspend fun wipeEverything(callServer: Boolean) {
        stopStream()
        drainJob?.cancel()
        outbox.entries.value.forEach { e -> e.attachments.forEach { runCatching { java.io.File(it.path).delete() } } }
        if (callServer) gateway.logout()
        data.wipe()
        outbox.clear()
        sessionHolder.record = null
        sessionFlow.value = null
        acceptedConsent.value = null
        threadsFlow.value = emptyMap()
        conversationsFlow.value = ConversationsState()
        unreadFlow.value = 0
        drafts.value = emptyMap()
        typingFlow.value = Typing()
        agentFlow.value = emptyMap()
        activeConversationId = null
        controllers.clear()
        blockedFlow.value = Blocked.NONE
        configFlow.value?.let { data.saveConfig(it) }
        registrar.reset()
        Guard.run("wipe hook") { hooks.onWiped() }
    }

    // ---- push ----

    @Volatile
    private var push: PushRegistration? = data.loadPushToken()

    internal fun setPushToken(token: String, environment: String?) {
        val reg = PushRegistration("fcm", token, environment)
        push = reg
        data.savePushToken(reg)
        scope.launch { registerDevice() }
    }

    private suspend fun registerDevice() = registrar.register()

    // ---- data calls (all behind the consent gate) ----

    private suspend fun <T> gated(block: suspend (ApiClient) -> T): T {
        if (gate() != Gate.OPEN) throw ConsentRequiredException()
        if (blockedFlow.value == Blocked.UNAVAILABLE) throw ApiException(403, ChatErrorCode.APP_DISABLED, ChatErrorCode.APP_DISABLED.wire)
        return gateway.authed(block)
    }

    internal suspend fun fetchMessages(conversationId: String, before: String? = null, after: String? = null): MessagesPage =
        gated { it.messages(conversationId, before = before, after = after) }

    internal suspend fun refreshUnread() {
        try {
            val n = gated { it.unread() }
            unreadFlow.value = n
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            Log.d("unread refresh failed")
        }
    }

    internal suspend fun loadConversations(): Boolean {
        conversationsFlow.update { it.copy(loading = true, failed = false) }
        return try {
            val page = gated { it.conversations() }
            conversationsFlow.value = ConversationsState(page.items)
            unreadFlow.value = page.unreadTotal
            activeConversationId = page.items.firstOrNull()?.id ?: activeConversationId
            Guard.run("save conversations") { data.saveConversations(page.items) }
            true
        } catch (e: CancellationException) {
            throw e
        } catch (e: ApiException) {
            handleTerminal(e)
            conversationsFlow.update { it.copy(loading = false, failed = true) }
            false
        } catch (t: Throwable) {
            conversationsFlow.update { it.copy(loading = false, failed = true) }
            false
        }
    }

    internal suspend fun markRead(conversationId: String, upTo: String) {
        try {
            unreadFlow.value = gated { it.read(conversationId, upTo) }
            conversationsFlow.update { s -> s.copy(items = s.items.map { if (it.id == conversationId) it.copy(unread = 0) else it }) }
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            Log.d("mark read failed")
        }
    }

    /** Called by a visible thread when an agent message is on screen. Debounced. */
    internal fun scheduleMarkRead(conversationId: String, upTo: String) {
        readJob?.cancel()
        readJob = scope.launch {
            delay(400)
            markRead(conversationId, upTo)
        }
    }

    // ---- threads ----

    internal fun thread(conversationId: String?): ThreadController = synchronized(controllers) {
        controllers.getOrPut(conversationId ?: "new-" + UUID.randomUUID()) { ThreadController(this, conversationId) }
    }

    internal fun releaseThread(controller: ThreadController) {
        synchronized(controllers) { controllers.values.remove(controller) }
    }

    internal fun threadData(conversationId: String): ThreadData = threadsFlow.value[conversationId] ?: ThreadData(data.loadThread(conversationId))

    internal fun putThread(conversationId: String, transform: (ThreadData) -> ThreadData) {
        threadsFlow.update { map ->
            val next = transform(map[conversationId] ?: ThreadData(data.loadThread(conversationId)))
            map + (conversationId to next)
        }
        val messages = threadsFlow.value[conversationId]?.messages ?: return
        scope.launch { Guard.run("save thread") { data.saveThread(conversationId, messages) } }
    }

    internal fun onServerMessagesArrived(messages: List<ChatMessage>) {
        val ids = messages.mapNotNull { it.clientMessageId }
        if (ids.isEmpty()) return
        outbox.onServerMessages(ids).forEach { e -> e.attachments.forEach { runCatching { java.io.File(it.path).delete() } } }
    }

    /** Enqueues a message. It is saved before the first try; sending starts at once. */
    internal fun enqueue(conversationId: String?, text: String, attachments: List<OutboxAttachment>): String {
        val id = UUID.randomUUID().toString()
        outbox.enqueue(
            OutboxEntry(
                clientMessageId = id,
                conversationId = conversationId,
                text = text,
                attachments = attachments,
                context = contextFlow.value,
                createdAtMs = clock.now(),
            ),
        )
        hooks.haptic(HapticKind.SEND)
        scope.launch {
            // A session is created here if the customer has none yet (consent was given on this screen).
            if (ensureSession()) drainOutbox() else scheduleDrain(5_000)
        }
        return id
    }

    internal fun retry(clientMessageId: String) {
        outbox.retryNow(clientMessageId)
        scope.launch { drainOutbox() }
    }

    internal fun cancelSend(clientMessageId: String) {
        sender.cancel(clientMessageId)
    }

    internal fun drainOutbox() {
        if (gate() != Gate.OPEN) return
        synchronized(this) {
            if (drainJob?.isActive == true) return
            drainJob = scope.launch {
                var wake: Long? = null
                try {
                    wake = sender.drain()
                } catch (e: CancellationException) {
                    throw e
                } catch (t: Throwable) {
                    Guard.report("drain", t)
                }
                if (wake != null) scheduleDrain((wake - clock.now()).coerceAtLeast(1_000))
            }
        }
    }

    private var drainTimer: Job? = null

    private fun scheduleDrain(afterMs: Long) {
        drainTimer?.cancel()
        drainTimer = scope.launch {
            delay(afterMs)
            rateLimited.value = false
            if (hooks.isForeground()) drainOutbox()
        }
    }

    // ---- stream ----

    private fun canStream(): Boolean = gate() == Gate.OPEN && sessionHolder.record != null && blockedFlow.value != Blocked.UNAVAILABLE

    internal fun startStream() {
        if (!canStream() || !hooks.isForeground()) return
        synchronized(this) {
            if (streamJob?.isActive == true) return
            streamJob = scope.launch { streamLoop() }
        }
    }

    internal fun stopStream() {
        synchronized(this) {
            streamJob?.cancel()
            streamJob = null
        }
        reconnectTimer?.cancel()
        connectionFlow.value = Connection.IDLE
        reconnectBanner.value = false
        typingFlow.value = Typing()
    }

    private suspend fun streamLoop() {
        val backoff = Backoff()
        while (scope.isActive && canStream()) {
            var serverWaitMs = 0L
            try {
                gateway.authed { client ->
                    client.events(
                        onOpen = {
                            connectionFlow.value = Connection.CONNECTED
                            reconnectBanner.value = false
                            reconnectTimer?.cancel()
                            backoff.reset()
                            scope.launch { catchUp() }
                        },
                        onEvent = { Guard.run("sse event") { handleEvent(it) } },
                    )
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: ApiException) {
                handleTerminal(e)
                if (e.reaction == Reaction.UNAVAILABLE || e.reaction == Reaction.LOGIN_NEEDED) return
                serverWaitMs = (e.retryAfterSeconds ?: 0L).coerceAtMost(MAX_STREAM_RETRY_AFTER_SECONDS) * 1_000
            } catch (_: ConsentRequiredException) {
                return
            } catch (_: LoginNeededException) {
                return
            } catch (_: Exception) {
                // network trouble: reconnect below
            }
            markDown()
            delay(maxOf(backoff.nextDelayMs(), serverWaitMs))
        }
    }

    private fun markDown() {
        if (connectionFlow.value != Connection.RECONNECTING) {
            connectionFlow.value = Connection.RECONNECTING
            reconnectTimer?.cancel()
            reconnectTimer = scope.launch {
                delay(3_000)
                if (connectionFlow.value == Connection.RECONNECTING) reconnectBanner.value = true
            }
        }
    }

    /** After (re)connect or foreground: unread, conversations, newer messages of open threads, the queue. */
    internal suspend fun catchUp() {
        if (gate() != Gate.OPEN || sessionHolder.record == null) return
        refreshUnread()
        loadConversations()
        val open = synchronized(controllers) { controllers.values.toList() }
        open.forEach { Guard.run("catch up thread") { it.refreshNewer() } }
        drainOutbox()
    }

    private fun handleEvent(ev: SseEvent) {
        when (ev.event) {
            "ready" -> {
                val obj = parseObject(ev.data) ?: return
                obj["conversationId"]?.jsonPrimitive?.contentOrNull?.let { activeConversationId = it }
            }
            "message" -> {
                val obj = parseObject(ev.data) ?: return
                val dto = try { ChatJson.decodeFromJsonElement(MessageDto.serializer(), obj) } catch (_: Exception) { return }
                val message = Decoders.message(dto) ?: return
                dto.conversationId?.let { activeConversationId = activeConversationId ?: it }
                onStreamMessage(dto.conversationId ?: activeConversationId, message)
            }
            "typing" -> {
                val obj = parseObject(ev.data) ?: return
                val active = obj["active"]?.jsonPrimitive?.booleanOrNull ?: false
                typingFlow.value = Typing(active, obj["agentName"]?.jsonPrimitive?.contentOrNull)
                typingTimer?.cancel()
                if (active) typingTimer = scope.launch { delay(8_000); typingFlow.value = Typing() }
            }
            "agent_joined" -> {
                val obj = parseObject(ev.data) ?: return
                val conv = activeConversationId ?: return
                val info = AgentInfo(obj["agentName"]?.jsonPrimitive?.contentOrNull, obj["agentAvatarUrl"]?.jsonPrimitive?.contentOrNull)
                agentFlow.update { it + (conv to info) }
            }
            "unread" -> {
                val obj = parseObject(ev.data) ?: return
                obj["unreadTotal"]?.jsonPrimitive?.intOrNull?.let { unreadFlow.value = it }
            }
            else -> Unit // unknown event: skipped
        }
    }

    private fun parseObject(text: String): JsonObject? = try {
        ChatJson.parseToJsonElement(text) as? JsonObject
    } catch (_: Exception) {
        null
    }

    private fun onStreamMessage(conversationId: String?, message: ChatMessage) {
        if (conversationId != null) putThread(conversationId) { ThreadMerge.add(it, message) }
        onServerMessagesArrived(listOf(message))
        if (message.fromVisitor) return
        typingFlow.value = Typing()
        hooks.onMessageReceived()
        val visible = hooks.isChatVisible()
        if (visible) {
            hooks.haptic(HapticKind.RECEIVE)
            hooks.playSoundIfAllowed(configFlow.value?.snapshot?.appearance?.soundEnabled == true)
            if (conversationId != null) scheduleMarkRead(conversationId, message.id)
        } else {
            unreadFlow.update { it + 1 }
            if (hooks.isForeground()) {
                val name = message.agentName ?: configFlow.value?.snapshot?.appearance?.brandName.orEmpty()
                hooks.showBanner(
                    BannerInfo(
                        conversationId = conversationId,
                        name = name,
                        avatarUrl = message.agentAvatarUrl,
                        preview = message.text.ifBlank { null },
                    ),
                )
            }
            hooks.playSoundIfAllowed(configFlow.value?.snapshot?.appearance?.soundEnabled == true)
        }
        if (conversationId == null || conversationsFlow.value.items.none { it.id == conversationId }) {
            scope.launch { loadConversations() }
        }
    }

    private fun EngineHooks.playSoundIfAllowed(enabled: Boolean) {
        if (enabled) playSound()
    }

    internal fun release() {
        Guard.run("release") {
            stopStream()
            drainJob?.cancel()
            drainTimer?.cancel()
            scope.coroutineContext[Job]?.cancel()
        }
    }
}
