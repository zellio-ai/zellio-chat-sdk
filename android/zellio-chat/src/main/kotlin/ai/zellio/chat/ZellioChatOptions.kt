package ai.zellio.chat

import android.graphics.Typeface

/** The language of the chat screens. [AUTO] follows the snapshot policy and the device language. */
public enum class ZellioLocale { AUTO, ARABIC, ENGLISH }

/** How much the SDK writes to Logcat. Chat text, tokens and headers are never logged at any level. */
public enum class ZellioLogLevel { NONE, ERROR, WARN, INFO, DEBUG }

/** Light, dark, or follow the device. */
public enum class ZellioThemeMode { AUTO, LIGHT, DARK }

/**
 * Theme overrides. Every field is optional; colors are `#RRGGBB`. A color that would make text hard to read is
 * adjusted automatically. [brandFont] is used for all chat text.
 */
public class ZellioTheme @JvmOverloads public constructor(
    public val mode: ZellioThemeMode? = null,
    public val primaryColor: String? = null,
    public val customerMessageColor: String? = null,
    public val surfaceColor: String? = null,
    public val brandFont: Typeface? = null,
)

/** Options for [ZellioChat.configure]. Build with [ZellioChatOptions.Builder] from Java. */
public class ZellioChatOptions @JvmOverloads public constructor(
    public val baseUrl: String = DEFAULT_BASE_URL,
    public val locale: ZellioLocale = ZellioLocale.AUTO,
    public val theme: ZellioTheme = ZellioTheme(),
    public val logLevel: ZellioLogLevel = ZellioLogLevel.WARN,
    /** Set by the React Native and Flutter wrappers so the server can tell them apart. Host apps leave it null. */
    public val wrapper: String? = null,
    /** Show a small banner at the top of the host app when a reply arrives while chat is closed. */
    public val showsInAppBanner: Boolean = true,
    /** The banner shows the first line of the reply. When false it says "New message". */
    public val bannerShowsPreview: Boolean = true,
) {
    public class Builder {
        private var baseUrl: String = DEFAULT_BASE_URL
        private var locale: ZellioLocale = ZellioLocale.AUTO
        private var theme: ZellioTheme = ZellioTheme()
        private var logLevel: ZellioLogLevel = ZellioLogLevel.WARN
        private var wrapper: String? = null
        private var showsInAppBanner: Boolean = true
        private var bannerShowsPreview: Boolean = true

        public fun baseUrl(value: String): Builder = apply { baseUrl = value }
        public fun locale(value: ZellioLocale): Builder = apply { locale = value }
        public fun theme(value: ZellioTheme): Builder = apply { theme = value }
        public fun logLevel(value: ZellioLogLevel): Builder = apply { logLevel = value }
        public fun wrapper(value: String?): Builder = apply { wrapper = value }
        public fun showsInAppBanner(value: Boolean): Builder = apply { showsInAppBanner = value }
        public fun bannerShowsPreview(value: Boolean): Builder = apply { bannerShowsPreview = value }
        public fun build(): ZellioChatOptions = ZellioChatOptions(baseUrl, locale, theme, logLevel, wrapper, showsInAppBanner, bannerShowsPreview)
    }

    public companion object {
        public const val DEFAULT_BASE_URL: String = "https://app.zellio.ai"
    }
}

/**
 * What the customer is looking at in the host app. Sent with the next messages. Text is cut to 200 characters and
 * [url] is kept only if it starts with `https://`.
 */
public class ZellioContext @JvmOverloads public constructor(
    public val screen: String? = null,
    public val itemType: String? = null,
    public val itemId: String? = null,
    public val itemTitle: String? = null,
    public val url: String? = null,
)

/** Async source of the customer's identity token (a JWT signed by the brand's server). Return null if logged out. */
public fun interface ZellioTokenProvider {
    public suspend fun token(): String?
}

/** Java-friendly token provider: call [Callback.onToken] once, from any thread. */
public fun interface ZellioTokenCallbackProvider {
    public fun requestToken(callback: Callback)

    public interface Callback {
        public fun onToken(token: String?)
        public fun onFailure(error: Throwable)
    }
}

/** Events for analytics in the host app. They carry no message text. */
public sealed interface ZellioChatEvent {
    public data object ChatOpened : ZellioChatEvent
    public data object ChatClosed : ZellioChatEvent
    public data object MessageSent : ZellioChatEvent
    public data object MessageReceived : ZellioChatEvent
    public data class Error(val code: String) : ZellioChatEvent
}

/** Java-friendly listener for [ZellioChatEvent]. Called on the main thread. */
public interface ZellioChatListener {
    public fun onChatOpened() {}
    public fun onChatClosed() {}
    public fun onMessageSent() {}
    public fun onMessageReceived() {}
    public fun onError(code: String) {}
}

/** Java-friendly listener for the unread count. Called on the main thread. */
public fun interface ZellioUnreadListener {
    public fun onUnreadCount(count: Int)
}
