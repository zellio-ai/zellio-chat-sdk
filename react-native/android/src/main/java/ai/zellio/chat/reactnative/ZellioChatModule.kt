package ai.zellio.chat.reactnative

import ai.zellio.chat.ZellioChat
import ai.zellio.chat.ZellioChatListener
import ai.zellio.chat.ZellioChatOptions
import ai.zellio.chat.ZellioContext
import ai.zellio.chat.ZellioLocale
import ai.zellio.chat.ZellioLogLevel
import ai.zellio.chat.ZellioTheme
import ai.zellio.chat.ZellioThemeMode
import ai.zellio.chat.ZellioTokenCallbackProvider
import ai.zellio.chat.ZellioUnreadListener
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * The Turbo Native Module. It holds no chat logic: every method calls the ZeeChat Android SDK and returns.
 * No exception leaves a method; the SDK has the same rule.
 */
class ZellioChatModule(reactContext: ReactApplicationContext) : NativeZellioChatSpec(reactContext) {
    private val main = Handler(Looper.getMainLooper())
    private val pendingTokens = ConcurrentHashMap<String, ZellioTokenCallbackProvider.Callback>()

    private val chatListener = object : ZellioChatListener {
        override fun onChatOpened() = emitEvent("chatOpened", null)
        override fun onChatClosed() = emitEvent("chatClosed", null)
        override fun onMessageSent() = emitEvent("messageSent", null)
        override fun onMessageReceived() = emitEvent("messageReceived", null)
        override fun onError(code: String) = emitEvent("error", code)
    }

    private val unreadListener = ZellioUnreadListener { count ->
        guarded("unread") {
            val payload = Arguments.createMap()
            payload.putDouble("count", count.toDouble())
            emitOnUnread(payload)
        }
    }

    init {
        guarded("init") {
            ZellioChat.addListener(chatListener)
            ZellioChat.addUnreadListener(unreadListener)
        }
    }

    override fun invalidate() {
        guarded("invalidate") {
            ZellioChat.removeListener(chatListener)
            ZellioChat.removeUnreadListener(unreadListener)
            failAllTokens("detached")
        }
        super.invalidate()
    }

    override fun configure(appKey: String, options: ReadableMap) = guarded("configure") {
        val locale = when (options.string("locale")) {
            "ar" -> ZellioLocale.ARABIC
            "en" -> ZellioLocale.ENGLISH
            else -> ZellioLocale.AUTO
        }
        val theme = ZellioTheme(
            mode = when (options.string("themeMode")) {
                "light" -> ZellioThemeMode.LIGHT
                "dark" -> ZellioThemeMode.DARK
                else -> null
            },
            primaryColor = options.string("primaryColor"),
            customerMessageColor = options.string("customerMessageColor"),
            surfaceColor = options.string("surfaceColor"),
        )
        val logLevel = when (options.string("logLevel")) {
            "none" -> ZellioLogLevel.NONE
            "error" -> ZellioLogLevel.ERROR
            "info" -> ZellioLogLevel.INFO
            "debug" -> ZellioLogLevel.DEBUG
            else -> ZellioLogLevel.WARN
        }
        ZellioChat.configure(
            reactApplicationContext,
            appKey,
            ZellioChatOptions(
                baseUrl = options.string("baseUrl") ?: ZellioChatOptions.DEFAULT_BASE_URL,
                locale = locale,
                theme = theme,
                logLevel = logLevel,
                wrapper = options.string("wrapper"),
                showsInAppBanner = options.bool("showsInAppBanner", true),
                bannerShowsPreview = options.bool("bannerShowsPreview", true),
            ),
        )
        // configure usually runs after the first Activity resumed, so tell the SDK which one is on screen.
        ZellioChat.attachActivity(reactApplicationContext.currentActivity)
    }

    override fun identify() = guarded("identify") {
        ZellioChat.identifyWithCallback(ZellioTokenCallbackProvider { callback -> requestToken(callback) })
    }

    override fun resolveToken(requestId: String, token: String?, errorCode: String?) = guarded("resolveToken") {
        val callback = pendingTokens.remove(requestId) ?: return@guarded
        when {
            !token.isNullOrEmpty() -> callback.onToken(token)
            // JavaScript says nobody is signed in: the SDK treats a null token as logged out.
            errorCode == "no_token" -> callback.onToken(null)
            else -> callback.onFailure(IllegalStateException(errorCode ?: "unknown"))
        }
    }

    override fun logout() = guarded("logout") { ZellioChat.logout() }

    override fun present() = guarded("present") { ZellioChat.present() }

    override fun presentConversation(conversationId: String?) = guarded("presentConversation") {
        ZellioChat.presentConversation(conversationId)
    }

    override fun dismiss() = guarded("dismiss") { ZellioChat.dismiss() }

    override fun setContext(context: ReadableMap?) = guarded("setContext") {
        ZellioChat.setContext(
            context?.let {
                ZellioContext(
                    screen = it.string("screen"),
                    itemType = it.string("itemType"),
                    itemId = it.string("itemId"),
                    itemTitle = it.string("itemTitle"),
                    url = it.string("url"),
                )
            },
        )
    }

    override fun getUnreadCount(promise: Promise) {
        promise.resolve(safe(0) { ZellioChat.currentUnreadCount() }.toDouble())
    }

    override fun setPushToken(token: String, environment: String?) = guarded("setPushToken") {
        ZellioChat.setPushToken(token, environment)
    }

    override fun isZellioPush(payloadJson: String): Boolean = safe(false) { ZellioChat.isZellioPush(payloadJson) }

    override fun handlePush(payloadJson: String, promise: Promise) {
        promise.resolve(safe(false) { ZellioChat.handlePush(payloadJson) })
    }

    override fun handleNotificationTap(payloadJson: String, promise: Promise) {
        promise.resolve(safe(false) { ZellioChat.handleNotificationTap(payloadJson) })
    }

    // ---- token requests: native asks JavaScript, JavaScript answers through resolveToken ----

    private fun requestToken(callback: ZellioTokenCallbackProvider.Callback) {
        val requestId = UUID.randomUUID().toString()
        pendingTokens[requestId] = callback
        // The first answer wins. This timer is the safety net when JavaScript never answers.
        main.postDelayed({
            pendingTokens.remove(requestId)?.onFailure(IllegalStateException("timeout"))
        }, TOKEN_TIMEOUT_MS)
        val payload = Arguments.createMap()
        payload.putString("requestId", requestId)
        emitOnTokenRequest(payload)
    }

    private fun failAllTokens(reason: String) {
        val ids = pendingTokens.keys.toList()
        for (id in ids) pendingTokens.remove(id)?.onFailure(IllegalStateException(reason))
    }

    // ---- helpers ----

    private fun emitEvent(name: String, code: String?) = guarded("event") {
        val payload = Arguments.createMap()
        payload.putString("name", name)
        if (code != null) payload.putString("code", code)
        emitOnEvent(payload)
    }

    private fun ReadableMap.string(key: String): String? =
        if (hasKey(key) && !isNull(key)) getString(key) else null

    private fun ReadableMap.bool(key: String, default: Boolean): Boolean =
        if (hasKey(key) && !isNull(key)) getBoolean(key) else default

    private inline fun guarded(name: String, block: () -> Unit) {
        try {
            block()
        } catch (t: Throwable) {
            // The kind of error only. Arguments can hold tokens, so they are never printed.
            Log.w(TAG, "$name failed (${t.javaClass.simpleName})")
        }
    }

    private inline fun <T> safe(fallback: T, block: () -> T): T = try {
        block()
    } catch (t: Throwable) {
        Log.w(TAG, "call failed (${t.javaClass.simpleName})")
        fallback
    }

    companion object {
        const val NAME = NativeZellioChatSpec.NAME
        private const val TAG = "ZellioChatRN"
        private const val TOKEN_TIMEOUT_MS = 15_000L
    }
}
