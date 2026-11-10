package ai.zellio.chat.internal

import ai.zellio.chat.BuildConfig
import ai.zellio.chat.ZellioChatActivity
import ai.zellio.chat.ZellioChatEvent
import ai.zellio.chat.ZellioChatOptions
import ai.zellio.chat.ZellioLocale
import ai.zellio.chat.ZellioThemeMode
import ai.zellio.chat.internal.core.Clock
import ai.zellio.chat.internal.core.FileStore
import ai.zellio.chat.internal.core.Guard
import ai.zellio.chat.internal.core.KeyValueStore
import ai.zellio.chat.internal.core.LocaleOption
import ai.zellio.chat.internal.core.Log
import ai.zellio.chat.internal.core.MemoryStore
import ai.zellio.chat.internal.core.ThemeOverrides
import ai.zellio.chat.internal.engine.BannerInfo
import ai.zellio.chat.internal.engine.ChatEngine
import ai.zellio.chat.internal.engine.EngineHooks
import ai.zellio.chat.internal.engine.HapticKind
import ai.zellio.chat.internal.platform.AndroidEnv
import ai.zellio.chat.internal.platform.ImageLoader
import ai.zellio.chat.internal.platform.InAppBanner
import ai.zellio.chat.internal.platform.KeystoreVault
import ai.zellio.chat.internal.platform.NetworkHint
import android.app.Activity
import android.app.Application
import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicInteger

/** What `present()` asks the chat to show. [explicit] false means "start where the layout says". */
internal data class PresentRequest(val conversationId: String?, val explicit: Boolean, val serial: Long)

/**
 * One per `configure`. Owns the engine and everything that needs Android: the process lifecycle, the visible
 * activity (for the in-app banner and haptics), the event fan-out and the unread mirror.
 */
internal class ChatRuntime(
    internal val app: Application,
    appKey: String,
    private val options: ZellioChatOptions,
    private val emit: (ZellioChatEvent) -> Unit,
    private val unreadSink: (Int) -> Unit,
    wrapper: String?,
) : EngineHooks {
    private val main = Handler(Looper.getMainLooper())
    private val job = SupervisorJob()
    internal val scope = CoroutineScope(job + Dispatchers.Default + Guard.handler)

    private val store: KeyValueStore = try {
        FileStore(File(app.noBackupFilesDir, "zellio-chat"))
    } catch (t: Throwable) {
        Guard.report("store", t)
        MemoryStore()
    }

    internal val images = ImageLoader(app)
    internal val brandFont = options.theme.brandFont

    private val localeOption = when (options.locale) {
        ZellioLocale.AUTO -> LocaleOption.AUTO
        ZellioLocale.ARABIC -> LocaleOption.AR
        ZellioLocale.ENGLISH -> LocaleOption.EN
    }

    private val appVersion: String? = try {
        app.packageManager.getPackageInfo(app.packageName, 0).versionName
    } catch (_: Throwable) {
        null
    }

    internal val engine = ChatEngine(
        appKey = appKey,
        baseUrl = options.baseUrl,
        sdkVersion = BuildConfig.SDK_VERSION,
        wrapper = wrapper,
        store = store,
        vault = KeystoreVault(store),
        clock = Clock.System,
        scope = scope,
        localeOption = localeOption,
        deviceLanguage = { app.resources.configuration.locales.get(0)?.language },
        themeOverrides = ThemeOverrides(
            mode = when (options.theme.mode) {
                ZellioThemeMode.LIGHT -> "light"
                ZellioThemeMode.DARK -> "dark"
                ZellioThemeMode.AUTO, null -> null
            },
            primaryColor = options.theme.primaryColor,
            customerMessageColor = options.theme.customerMessageColor,
            surfaceColor = options.theme.surfaceColor,
        ),
        appVersion = appVersion,
        hooks = this,
    )

    private val banner = InAppBanner { id -> main.post { present(PresentRequest(id, explicit = id != null, serial = System.nanoTime())) } }
    private val network = NetworkHint(app) { engine.drainOutbox() }

    private val visibleChats = AtomicInteger(0)
    private val openChats = AtomicInteger(0)

    @Volatile
    private var resumed: WeakReference<Activity>? = null

    @Volatile
    internal var hapticView: WeakReference<View>? = null

    @Volatile
    private var foreground = false

    private val activityCallbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(activity: Activity) {
            resumed = WeakReference(activity)
        }

        override fun onActivityPaused(activity: Activity) {
            if (resumed?.get() === activity) resumed = null
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
        override fun onActivityStarted(activity: Activity) = Unit
        override fun onActivityStopped(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
        override fun onActivityDestroyed(activity: Activity) = Unit
    }

    private val processObserver = object : DefaultLifecycleObserver {
        override fun onStart(owner: LifecycleOwner) {
            foreground = true
            engine.onForeground()
            network.start()
        }

        override fun onStop(owner: LifecycleOwner) {
            foreground = false
            engine.onBackground()
            banner.dismiss(animated = false)
            network.stop()
        }
    }

    init {
        scope.launch { engine.start() }
        scope.launch { engine.unread.collect { unreadSink(it) } }
        main.post {
            Guard.run("register lifecycle") {
                app.registerActivityLifecycleCallbacks(activityCallbacks)
                ProcessLifecycleOwner.get().lifecycle.addObserver(processObserver)
            }
        }
        Log.i("configured")
    }

    // ---- hooks ----

    /** Tells the runtime which Activity is on screen when configure ran after that Activity resumed. Held weakly. */
    internal fun attachActivity(activity: Activity) {
        if (resumed?.get() == null && !activity.isFinishing) resumed = WeakReference(activity)
    }

    override fun isForeground(): Boolean = foreground

    override fun isChatVisible(): Boolean = visibleChats.get() > 0

    override fun onMessageSent() = emit(ZellioChatEvent.MessageSent)

    override fun onMessageReceived() = emit(ZellioChatEvent.MessageReceived)

    override fun onError(code: String) = emit(ZellioChatEvent.Error(code))

    override fun showBanner(info: BannerInfo) {
        if (!options.showsInAppBanner) return
        val shown = if (options.bannerShowsPreview) info else info.copy(preview = null)
        main.post {
            Guard.run("banner") {
                val activity = resumed?.get() ?: return@post
                if (activity is ZellioChatActivity || activity.isFinishing) return@post
                val night = activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
                banner.show(
                    activity, shown, engine.palette(night == Configuration.UI_MODE_NIGHT_YES), engine.locale(),
                    engine.appearance().brandName, AndroidEnv.reducedMotion(app),
                )
            }
        }
    }

    override fun haptic(kind: HapticKind) {
        main.post {
            val view = hapticView?.get() ?: resumed?.get()?.window?.decorView ?: return@post
            AndroidEnv.haptic(view, kind)
        }
    }

    override fun playSound() {
        AndroidEnv.playSound(app)
    }

    /** Runs on every logout and customer switch, whether or not a chat screen is open. */
    override fun onWiped() {
        images.clearDisk()
        Guard.run("clear camera files") { File(app.cacheDir, "zellio-camera").deleteRecursively() }
    }

    // ---- chat window bookkeeping ----

    internal fun chatEntered() {
        if (openChats.incrementAndGet() == 1) emit(ZellioChatEvent.ChatOpened)
        banner.dismiss(animated = false)
    }

    internal fun chatLeft() {
        if (openChats.updateAndGet { (it - 1).coerceAtLeast(0) } == 0) emit(ZellioChatEvent.ChatClosed)
    }

    internal fun chatVisible(value: Boolean) {
        if (value) visibleChats.incrementAndGet() else visibleChats.updateAndGet { (it - 1).coerceAtLeast(0) }
    }

    // ---- presenting ----

    internal fun present(request: PresentRequest) {
        Guard.run("present") {
            val intent = Intent(app, ZellioChatActivity::class.java)
                .putExtra(ZellioChatActivity.EXTRA_CONVERSATION_ID, request.conversationId)
                .putExtra(ZellioChatActivity.EXTRA_EXPLICIT, request.explicit)
                .putExtra(ZellioChatActivity.EXTRA_SERIAL, request.serial)
            val host = resumed?.get()
            if (host != null && !host.isFinishing) {
                host.startActivity(intent)
            } else {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                app.startActivity(intent)
            }
        }
    }

    internal fun dismiss() {
        main.post { Guard.run("dismiss") { ZellioChatActivity.finishAll() } }
    }

    internal fun release() {
        Guard.run("release") {
            engine.release()
            main.post {
                Guard.run("unregister lifecycle") {
                    app.unregisterActivityLifecycleCallbacks(activityCallbacks)
                    ProcessLifecycleOwner.get().lifecycle.removeObserver(processObserver)
                    network.stop()
                    banner.dismiss(animated = false)
                }
            }
            job.cancel()
        }
    }
}
