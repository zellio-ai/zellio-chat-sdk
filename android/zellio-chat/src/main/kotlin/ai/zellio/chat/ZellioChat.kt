package ai.zellio.chat

import ai.zellio.chat.internal.ChatRuntime
import ai.zellio.chat.internal.PresentRequest
import ai.zellio.chat.internal.core.ChatContext
import ai.zellio.chat.internal.core.Guard
import ai.zellio.chat.internal.core.Log
import ai.zellio.chat.internal.core.LogLevel
import ai.zellio.chat.internal.core.LogSink
import ai.zellio.chat.internal.core.PushParser
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * ZeeChat for Android. Every call is safe from any thread, never blocks the caller, and never throws. A call made
 * before [configure] writes one log line and does nothing.
 */
public object ZellioChat {
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var runtime: ChatRuntime? = null

    @Volatile
    private var configuredWith: String? = null

    @Volatile
    private var attachedActivity: java.lang.ref.WeakReference<Activity>? = null

    private val listeners = CopyOnWriteArrayList<ZellioChatListener>()
    private val unreadListeners = CopyOnWriteArrayList<ZellioUnreadListener>()
    private val unreadState = MutableStateFlow(0)
    private val eventFlow = MutableSharedFlow<ZellioChatEvent>(extraBufferCapacity = 64, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    /** Unread messages across the customer's conversations. Updates on any thread. */
    @get:JvmStatic
    public val unreadCount: StateFlow<Int> = unreadState.asStateFlow()

    /** `chatOpened`, `chatClosed`, `messageSent`, `messageReceived` and `error(code)`. No message text. */
    @get:JvmStatic
    public val events: SharedFlow<ZellioChatEvent> = eventFlow.asSharedFlow()

    init {
        Log.sink = LogSink { level, message ->
            val priority = when (level) {
                LogLevel.ERROR -> android.util.Log.ERROR
                LogLevel.WARN -> android.util.Log.WARN
                LogLevel.INFO -> android.util.Log.INFO
                else -> android.util.Log.DEBUG
            }
            android.util.Log.println(priority, "ZellioChat", message)
        }
    }

    /**
     * Call once at app start (for example in `Application.onCreate`). Cheap: no network, no UI, no disk on the
     * calling thread. A second call with the same arguments does nothing; with other arguments it starts over.
     */
    @JvmStatic
    @JvmOverloads
    public fun configure(context: Context, appKey: String, options: ZellioChatOptions = ZellioChatOptions()) {
        guarded("configure") {
            val app = context.applicationContext as? Application ?: run {
                Log.e("configure needs an application context")
                return
            }
            if (appKey.isBlank()) {
                Log.e("configure needs an app key")
                return
            }
            Log.level = when (options.logLevel) {
                ZellioLogLevel.NONE -> LogLevel.NONE
                ZellioLogLevel.ERROR -> LogLevel.ERROR
                ZellioLogLevel.WARN -> LogLevel.WARN
                ZellioLogLevel.INFO -> LogLevel.INFO
                ZellioLogLevel.DEBUG -> LogLevel.DEBUG
            }
            val signature = listOf(appKey, options.baseUrl, options.locale, options.theme.mode, options.theme.primaryColor,
                options.theme.customerMessageColor, options.theme.surfaceColor, options.theme.brandFont, options.wrapper, options.showsInAppBanner,
                options.bannerShowsPreview).joinToString("|")
            synchronized(this) {
                if (runtime != null && configuredWith == signature) return
                runtime?.release()
                configuredWith = signature
                runtime = ChatRuntime(app, appKey, options, ::dispatch, ::dispatchUnread, options.wrapper).also { rt ->
                    attachedActivity?.get()?.let { rt.attachActivity(it) }
                }
            }
        }
    }

    /**
     * Marks a logged-in customer. [tokenProvider] returns a JWT from the brand's server (or null when logged out).
     * The SDK calls it when it needs a session, and once more if the server rejects the token.
     */
    @JvmStatic
    public fun identify(tokenProvider: ZellioTokenProvider) {
        withRuntime("identify") { it.engine.identify { tokenProvider.token() } }
    }

    /** The same for Java: answer through the callback, once. */
    @JvmStatic
    public fun identifyWithCallback(provider: ZellioTokenCallbackProvider) {
        withRuntime("identify") {
            it.engine.identify {
                suspendCancellableCoroutine { cont ->
                    try {
                        provider.requestToken(object : ZellioTokenCallbackProvider.Callback {
                            override fun onToken(token: String?) {
                                if (cont.isActive) cont.resume(token)
                            }

                            override fun onFailure(error: Throwable) {
                                if (cont.isActive) cont.resumeWithException(error)
                            }
                        })
                    } catch (t: Throwable) {
                        if (cont.isActive) cont.resumeWithException(t)
                    }
                }
            }
        }
    }

    /** Ends the session, deletes all local chat data and removes the push token from the server. */
    @JvmStatic
    public fun logout() {
        withRuntime("logout") { it.engine.logout() }
    }

    /** Shows chat on top of the app: the home screen, or the thread when the layout is chat-only. */
    @JvmStatic
    public fun present() {
        withRuntime("present") { it.present(PresentRequest(null, explicit = false, serial = System.nanoTime())) }
    }

    /** Opens one conversation, or a new one when [conversationId] is null. */
    @JvmStatic
    public fun presentConversation(conversationId: String?) {
        withRuntime("presentConversation") { it.present(PresentRequest(conversationId, explicit = true, serial = System.nanoTime())) }
    }

    /** Closes chat. */
    @JvmStatic
    public fun dismiss() {
        withRuntime("dismiss") { it.dismiss() }
    }

    /** Tells the SDK what the customer is looking at. It is sent with the next messages. Null clears it. */
    @JvmStatic
    public fun setContext(context: ZellioContext?) {
        withRuntime("setContext") { it.engine.setContext(context?.let(::sanitize)) }
    }

    /** Gives the SDK the FCM token. Call it from `onNewToken` and after login. */
    @JvmStatic
    @JvmOverloads
    public fun setPushToken(token: String, environment: String? = null) {
        withRuntime("setPushToken") {
            if (token.isBlank()) return@withRuntime
            it.engine.setPushToken(token, environment?.takeIf { e -> e == "sandbox" || e == "production" })
        }
    }

    /** True only if the payload has the `zellio` key. */
    @JvmStatic
    public fun isZellioPush(payload: Map<String, String>?): Boolean = safe(false) { PushParser.isOurs(payload) }

    /** The same for an `Intent` extras bundle, such as the one of a tapped notification. */
    @JvmStatic
    public fun isZellioPush(payload: Bundle?): Boolean = safe(false) { PushParser.isOurs(bundleToMap(payload)) }

    /** The same for the JSON text of the data payload (React Native and Flutter). */
    @JvmStatic
    public fun isZellioPush(payloadJson: String?): Boolean = safe(false) { PushParser.isOurs(payloadJson?.let { j -> PushParser.toMap(j) }) }

    /** Refreshes the unread state. Returns true if the push was ours. */
    @JvmStatic
    public fun handlePush(payload: Map<String, String>?): Boolean = safe(false) {
        if (!PushParser.isOurs(payload)) return@safe false
        runtime?.let { rt ->
            if (rt.engine.session.value != null) rt.scope.launch(Guard.handler) { rt.engine.refreshUnread() }
        } ?: Log.w("handlePush called before configure")
        true
    }

    /**
     * For wrappers (React Native, Flutter) that call [configure] after the first Activity resumed: gives the SDK the
     * Activity on screen so banners and presenting work at once. Held weakly, so it cannot leak the Activity.
     */
    @JvmStatic
    public fun attachActivity(activity: Activity?) {
        safe(Unit) {
            attachedActivity = activity?.let { java.lang.ref.WeakReference(it) }
            if (activity != null) runtime?.attachActivity(activity)
        }
    }

    /** Opens the conversation that the push names. Returns true if the push was ours. */
    @JvmStatic
    public fun handleNotificationTap(payload: Map<String, String>?): Boolean = safe(false) {
        if (!PushParser.isOurs(payload)) return@safe false
        val target = PushParser.parse(payload)?.conversationId
        val rt = runtime
        if (rt == null) Log.w("handleNotificationTap called before configure")
        else rt.present(PresentRequest(target, explicit = target != null, serial = System.nanoTime()))
        true
    }

    /** The same for the extras of the `Intent` that a tapped notification started. */
    @JvmStatic
    public fun handleNotificationTap(extras: Bundle?): Boolean = handleNotificationTap(bundleToMap(extras))

    /** Convenience: [handleNotificationTap] for `activity.intent` (call in `onCreate` and `onNewIntent`). */
    @JvmStatic
    public fun handleNotificationTap(intent: Intent?): Boolean = handleNotificationTap(intent?.extras)

    /** The same for the JSON text of the data payload (React Native and Flutter). */
    @JvmStatic
    public fun handlePush(payloadJson: String?): Boolean =
        safe(false) { handlePush(payloadJson?.let { PushParser.toMap(it)?.mapValues { e -> e.value?.toString().orEmpty() } }) }

    /** The same for the JSON text of the data payload (React Native and Flutter). */
    @JvmStatic
    public fun handleNotificationTap(payloadJson: String?): Boolean =
        safe(false) { handleNotificationTap(payloadJson?.let { PushParser.toMap(it)?.mapValues { e -> e.value?.toString().orEmpty() } }) }

    /** Adds a listener for the chat events. Called on the main thread. */
    @JvmStatic
    public fun addListener(listener: ZellioChatListener) {
        listeners.addIfAbsent(listener)
    }

    @JvmStatic
    public fun removeListener(listener: ZellioChatListener) {
        listeners.remove(listener)
    }

    /** Adds a listener for the unread count. It is called once with the current value. Main thread. */
    @JvmStatic
    public fun addUnreadListener(listener: ZellioUnreadListener) {
        if (unreadListeners.addIfAbsent(listener)) main.post { guarded("unread listener") { listener.onUnreadCount(unreadState.value) } }
    }

    @JvmStatic
    public fun removeUnreadListener(listener: ZellioUnreadListener) {
        unreadListeners.remove(listener)
    }

    /** The unread count right now (for Java). */
    @JvmStatic
    public fun currentUnreadCount(): Int = unreadState.value

    // ---- internals ----

    private fun dispatch(event: ZellioChatEvent) {
        eventFlow.tryEmit(event)
        if (listeners.isEmpty()) return
        main.post {
            listeners.forEach { l ->
                guarded("listener") {
                    when (event) {
                        ZellioChatEvent.ChatOpened -> l.onChatOpened()
                        ZellioChatEvent.ChatClosed -> l.onChatClosed()
                        ZellioChatEvent.MessageSent -> l.onMessageSent()
                        ZellioChatEvent.MessageReceived -> l.onMessageReceived()
                        is ZellioChatEvent.Error -> l.onError(event.code)
                    }
                }
            }
        }
    }

    private fun dispatchUnread(count: Int) {
        if (unreadState.value == count) return
        unreadState.value = count
        if (unreadListeners.isEmpty()) return
        main.post { unreadListeners.forEach { l -> guarded("unread listener") { l.onUnreadCount(count) } } }
    }

    internal fun runtimeOrNull(): ChatRuntime? = runtime

    private fun sanitize(c: ZellioContext) = ChatContext(
        screen = c.screen?.take(200),
        itemType = c.itemType?.take(200),
        itemId = c.itemId?.take(200),
        itemTitle = c.itemTitle?.take(200),
        url = c.url?.takeIf { it.startsWith("https://") }?.take(200),
    )

    private fun bundleToMap(bundle: Bundle?): Map<String, String>? {
        if (bundle == null) return null
        val out = HashMap<String, String>()
        for (key in bundle.keySet()) {
            @Suppress("DEPRECATION")
            bundle.get(key)?.let { out[key] = it.toString() }
        }
        return out
    }

    private inline fun withRuntime(name: String, block: (ChatRuntime) -> Unit) {
        guarded(name) {
            val rt = runtime
            if (rt == null) Log.w("$name called before configure") else block(rt)
        }
    }

    private inline fun guarded(name: String, block: () -> Unit) {
        try {
            block()
        } catch (t: Throwable) {
            Guard.report(name, t)
        }
    }

    private inline fun <T> safe(fallback: T, block: () -> T): T = try {
        block()
    } catch (t: Throwable) {
        Guard.report("push helper", t)
        fallback
    }
}
