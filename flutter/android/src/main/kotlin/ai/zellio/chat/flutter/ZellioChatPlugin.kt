package ai.zellio.chat.flutter

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
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * A thin bridge between Dart and the native ZeeChat SDK. It holds no chat logic and draws nothing.
 * Method and event names match `lib/src/zellio_chat.dart`.
 */
class ZellioChatPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware, PluginRegistry.NewIntentListener {
    private val main = Handler(Looper.getMainLooper())
    private var appContext: Context? = null
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var unread: EventChannel? = null
    private var activityBinding: ActivityPluginBinding? = null

    @Volatile
    private var configured = false

    // A tapped system-tray notification can start the app before Dart has called configure. Keep it until then.
    private var pendingTap: Map<String, String>? = null
    private var lastIntent: Intent? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "ai.zellio.chat/methods").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "ai.zellio.chat/events").also { it.setStreamHandler(EventsHandler()) }
        unread = EventChannel(binding.binaryMessenger, "ai.zellio.chat/unread").also { it.setStreamHandler(UnreadHandler()) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        unread?.setStreamHandler(null)
        methods = null
        events = null
        unread = null
        appContext = null
    }

    // ---- ActivityAware ----

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        if (configured) ZellioChat.attachActivity(binding.activity)
        binding.addOnNewIntentListener(this)
        inspectIntent(binding.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    private fun detachActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }

    override fun onNewIntent(intent: Intent): Boolean {
        inspectIntent(intent)
        return false
    }

    /** A tapped FCM notification carries its data payload as intent extras. Open the chat once per intent. */
    private fun inspectIntent(intent: Intent?) {
        try {
            if (intent == null || intent === lastIntent) return
            lastIntent = intent
            val extras: Bundle = intent.extras ?: return
            if (!ZellioChat.isZellioPush(extras)) return
            val payload = HashMap<String, String>()
            for (key in extras.keySet()) {
                @Suppress("DEPRECATION")
                extras.get(key)?.let { payload[key] = it.toString() }
            }
            if (configured) {
                ZellioChat.handleNotificationTap(payload)
            } else {
                pendingTap = payload
            }
        } catch (t: Throwable) {
            Log.w(TAG, "notification intent failed (${t.javaClass.simpleName})")
        }
    }

    // ---- Method channel ----

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "configure" -> {
                    configure(call)
                    result.success(null)
                }
                "identify" -> {
                    ZellioChat.identifyWithCallback(ZellioTokenCallbackProvider { callback -> requestToken(callback) })
                    result.success(null)
                }
                "logout" -> {
                    ZellioChat.logout()
                    result.success(null)
                }
                "present" -> {
                    ZellioChat.present()
                    result.success(null)
                }
                "presentConversation" -> {
                    ZellioChat.presentConversation(call.argument<String>("conversationId"))
                    result.success(null)
                }
                "dismiss" -> {
                    ZellioChat.dismiss()
                    result.success(null)
                }
                "setContext" -> {
                    ZellioChat.setContext(if (call.arguments == null) null else contextFrom(call))
                    result.success(null)
                }
                "unreadCount" -> result.success(ZellioChat.currentUnreadCount())
                "setPushToken" -> {
                    val token = call.argument<String>("token")
                    if (!token.isNullOrBlank()) ZellioChat.setPushToken(token, call.argument<String>("environment"))
                    result.success(null)
                }
                "isZellioPush" -> result.success(ZellioChat.isZellioPush(payloadOf(call)))
                "handlePush" -> result.success(ZellioChat.handlePush(payloadOf(call)))
                "handleNotificationTap" -> result.success(ZellioChat.handleNotificationTap(payloadOf(call)))
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            // Never let an SDK fault reach the host app. Dart ignores this answer.
            Log.w(TAG, "${call.method} failed (${t.javaClass.simpleName})")
            result.error("native_error", t.javaClass.simpleName, null)
        }
    }

    private fun configure(call: MethodCall) {
        val context = appContext ?: return
        val appKey = call.argument<String>("appKey") ?: return
        val theme = call.argument<Map<String, Any?>>("theme")
        val options = ZellioChatOptions(
            baseUrl = call.argument<String>("baseUrl")?.takeIf { it.isNotBlank() } ?: ZellioChatOptions.DEFAULT_BASE_URL,
            locale = when (call.argument<String>("locale")) {
                "ar" -> ZellioLocale.ARABIC
                "en" -> ZellioLocale.ENGLISH
                else -> ZellioLocale.AUTO
            },
            theme = ZellioTheme(
                mode = when (theme?.get("mode")) {
                    "light" -> ZellioThemeMode.LIGHT
                    "dark" -> ZellioThemeMode.DARK
                    else -> ZellioThemeMode.AUTO
                },
                primaryColor = theme?.get("primaryColor") as? String,
                customerMessageColor = theme?.get("customerMessageColor") as? String,
                surfaceColor = theme?.get("surfaceColor") as? String,
            ),
            logLevel = when (call.argument<String>("logLevel")) {
                "none" -> ZellioLogLevel.NONE
                "warn" -> ZellioLogLevel.WARN
                "info" -> ZellioLogLevel.INFO
                "debug" -> ZellioLogLevel.DEBUG
                else -> ZellioLogLevel.ERROR
            },
            wrapper = call.argument<String>("wrapper"),
            showsInAppBanner = call.argument<Boolean>("showsInAppBanner") ?: true,
            bannerShowsPreview = call.argument<Boolean>("bannerShowsPreview") ?: true,
        )
        ZellioChat.configure(context, appKey, options)
        // configure usually runs after the first Activity resumed, so tell the SDK which one is on screen.
        ZellioChat.attachActivity(activityBinding?.activity)
        configured = true
        pendingTap?.let {
            pendingTap = null
            ZellioChat.handleNotificationTap(it)
        }
    }

    private fun contextFrom(call: MethodCall) = ZellioContext(
        screen = call.argument<String>("screen"),
        itemType = call.argument<String>("itemType"),
        itemId = call.argument<String>("itemId"),
        itemTitle = call.argument<String>("itemTitle"),
        url = call.argument<String>("url"),
    )

    private fun payloadOf(call: MethodCall): Map<String, String> {
        val out = HashMap<String, String>()
        (call.arguments as? Map<*, *>)?.forEach { (k, v) ->
            if (k is String && v is String) out[k] = v
        }
        return out
    }

    /** Asks Dart for the token. Dart times out after 15 s; this guard answers after 20 s if Dart never does. */
    private fun requestToken(callback: ZellioTokenCallbackProvider.Callback) {
        val done = AtomicBoolean(false)
        val timeout = Runnable {
            if (done.compareAndSet(false, true)) callback.onFailure(TimeoutException("token request"))
        }
        val fail = { reason: String ->
            if (done.compareAndSet(false, true)) {
                main.removeCallbacks(timeout)
                callback.onFailure(IllegalStateException(reason))
            }
        }
        main.postDelayed(timeout, NATIVE_TOKEN_TIMEOUT_MS)
        main.post {
            val channel = methods
            if (channel == null) {
                fail("no_channel")
                return@post
            }
            try {
                channel.invokeMethod("identifyToken", null, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        if (done.compareAndSet(false, true)) {
                            main.removeCallbacks(timeout)
                            callback.onToken((result as? String)?.takeIf { it.isNotEmpty() })
                        }
                    }

                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) = fail(errorCode)

                    override fun notImplemented() = fail("not_implemented")
                })
            } catch (t: Throwable) {
                fail(t.javaClass.simpleName)
            }
        }
    }

    // ---- Event channels ----

    private inner class EventsHandler : EventChannel.StreamHandler {
        private var listener: ZellioChatListener? = null

        override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
            fun send(type: String, code: String? = null) {
                try {
                    sink.success(if (code == null) mapOf("type" to type) else mapOf("type" to type, "code" to code))
                } catch (t: Throwable) {
                    Log.w(TAG, "event failed (${t.javaClass.simpleName})")
                }
            }
            val l = object : ZellioChatListener {
                override fun onChatOpened() = send("chatOpened")
                override fun onChatClosed() = send("chatClosed")
                override fun onMessageSent() = send("messageSent")
                override fun onMessageReceived() = send("messageReceived")
                override fun onError(code: String) = send("error", code)
            }
            listener = l
            ZellioChat.addListener(l)
        }

        override fun onCancel(arguments: Any?) {
            listener?.let { ZellioChat.removeListener(it) }
            listener = null
        }
    }

    private inner class UnreadHandler : EventChannel.StreamHandler {
        private var listener: ZellioUnreadListener? = null

        override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
            val l = ZellioUnreadListener { count ->
                try {
                    sink.success(count)
                } catch (t: Throwable) {
                    Log.w(TAG, "unread failed (${t.javaClass.simpleName})")
                }
            }
            listener = l
            ZellioChat.addUnreadListener(l)
        }

        override fun onCancel(arguments: Any?) {
            listener?.let { ZellioChat.removeUnreadListener(it) }
            listener = null
        }
    }

    private companion object {
        const val TAG = "ZellioChatFlutter"
        const val NATIVE_TOKEN_TIMEOUT_MS = 20_000L
    }
}
