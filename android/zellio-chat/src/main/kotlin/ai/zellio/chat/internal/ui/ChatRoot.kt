package ai.zellio.chat.internal.ui

import ai.zellio.chat.R
import ai.zellio.chat.internal.ChatRuntime
import ai.zellio.chat.internal.core.Blocked
import ai.zellio.chat.internal.core.ConsentTerms
import ai.zellio.chat.internal.core.Gate
import ai.zellio.chat.internal.platform.AndroidEnv
import ai.zellio.chat.internal.engine.ChatNavigator
import ai.zellio.chat.internal.engine.Route
import ai.zellio.chat.internal.engine.StartRoute
import android.app.Activity
import android.content.ContextWrapper
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.collectAsState
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import java.lang.ref.WeakReference

/** What the root should open first. [explicit] false means: wherever the `layout` of the snapshot says. */
internal data class StartRequest(val conversationId: String?, val explicit: Boolean)

/**
 * The whole chat: theme, navigation, and the states that sit above any screen (loading, unavailable, login needed,
 * consent, image viewer). Used by the Activity and by the public `ZellioChatScreen`.
 */
@Composable
internal fun ChatRoot(
    runtime: ChatRuntime,
    start: StartRequest,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
    windowed: Boolean = false,
) {
    val engine = runtime.engine
    val context = LocalContext.current
    val configuration = LocalConfiguration.current
    val view = LocalView.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle

    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(configuration) {
        engine.onLocaleChanged()
        tick++
    }
    DisposableEffect(Unit) {
        runtime.chatEntered()
        runtime.hapticView = WeakReference(view)
        onDispose { runtime.chatLeft() }
    }
    DisposableEffect(lifecycle) {
        var visible = false
        fun set(value: Boolean) {
            if (visible != value) {
                visible = value
                runtime.chatVisible(value)
            }
        }
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> set(true)
                Lifecycle.Event.ON_PAUSE -> set(false)
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) set(true)
        onDispose {
            lifecycle.removeObserver(observer)
            set(false)
        }
    }

    val config by engine.config.collectAsState()
    val blocked by engine.blocked.collectAsState()
    val failed by engine.configLoadFailed.collectAsState()
    val accepted by engine.acceptedTerms.collectAsState()
    val systemDark = isSystemInDarkTheme()

    val snapshot = config?.snapshot
    val appearance = snapshot?.appearance
    val locale = remember(config, tick) { engine.locale() }
    val palette = remember(config, systemDark) { engine.palette(systemDark) }
    val colors = remember(palette) { ChatColors(palette) }
    val localized = remember(context, locale, configuration) { AndroidEnv.localizedContext(context, locale) }
    val reduced = remember(configuration) { AndroidEnv.reducedMotion(context) }
    val font = remember(runtime.brandFont) { runtime.brandFont?.let { FontFamily(it) } }
    val env = remember(colors, locale, localized, reduced, font, config) {
        ChatEnv(
            colors = colors,
            shapes = engine.shapes(),
            type = ChatType(font, locale.rtl),
            strings = Strings(localized),
            locale = locale,
            reducedMotion = reduced,
            engine = engine,
            images = runtime.images,
            brandName = appearance?.brandName.orEmpty(),
            logoUrl = config?.assets?.logoUrl,
            showAvatars = appearance?.showAgentAvatar ?: true,
        )
    }

    var navigator by remember(start) {
        mutableStateOf<ChatNavigator?>(
            if (start.explicit) ChatNavigator(StartRoute.forLayout(null, start.conversationId, true)) else null,
        )
    }
    LaunchedEffect(snapshot?.layout, start) {
        if (navigator == null && snapshot != null) {
            navigator = ChatNavigator(StartRoute.forLayout(snapshot.layout, null, false))
        }
    }

    if (windowed) {
        // The window follows the chat, not the device theme: a dark chat on a light phone needs light bar icons,
        // and so does a colored Home header or the photo viewer.
        val top = navigator?.stack?.collectAsState()?.value?.lastOrNull()
        val viewerOpen = navigator?.viewer?.collectAsState()?.value != null
        val onHomeHeader = top == Route.Home && snapshot != null && blocked == Blocked.NONE && configuration.screenWidthDp < 600
        val view = LocalView.current
        SideEffect {
            val window = generateSequence(view.context) { (it as? ContextWrapper)?.baseContext }.filterIsInstance<Activity>().firstOrNull()?.window
            if (window != null) {
                val bars = WindowCompat.getInsetsController(window, view)
                bars.isAppearanceLightStatusBars = !viewerOpen && palette.darkStatusIcons(onHomeHeader)
                bars.isAppearanceLightNavigationBars = !palette.dark
            }
        }
    }

    ProvideChat(env) {
        BoxWithConstraints(modifier.fillMaxSize()) {
            val tablet = windowed && maxWidth >= 600.dp
            if (tablet) {
                Box(
                    Modifier.fillMaxSize().background(colors.scrim)
                        .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onClose)
                        // The card sits in the space above the keyboard. The composer then adds no keyboard inset of its own.
                        .imePadding(),
                    contentAlignment = Alignment.Center,
                ) {
                    Box(
                        Modifier.widthIn(max = 640.dp).fillMaxWidth().heightIn(max = 860.dp).fillMaxHeight(0.92f)
                            .clip(RoundedCornerShape(28.dp))
                            .background(colors.bg)
                            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
                            .consumeWindowInsets(WindowInsets.statusBars.union(WindowInsets.navigationBars)),
                    ) {
                        ChatBody(env, navigator, snapshot != null, blocked, failed, accepted, onClose, engineRetry = engine::refreshConfig)
                    }
                }
            } else {
                Box(Modifier.fillMaxSize().background(colors.bg)) {
                    ChatBody(env, navigator, snapshot != null, blocked, failed, accepted, onClose, engineRetry = engine::refreshConfig)
                }
            }
        }
    }
}

@Composable
private fun ChatBody(
    env: ChatEnv,
    navigator: ChatNavigator?,
    hasSnapshot: Boolean,
    blocked: Blocked,
    failed: Boolean,
    accepted: ConsentTerms?,
    onClose: () -> Unit,
    engineRetry: () -> Unit,
) {
    val s = env.strings
    val config by env.engine.config.collectAsState()
    val snapshot = config?.snapshot
    val viewer = navigator?.viewer?.collectAsState()?.value

    BackHandler(enabled = true) {
        if (navigator == null || !navigator.back()) onClose()
    }

    when {
        blocked == Blocked.UNAVAILABLE -> UnavailableScreen(s[R.string.zc_state_unavailable], Icons.alert, onClose)
        blocked == Blocked.LOGIN_NEEDED -> UnavailableScreen(s[R.string.zc_state_login_needed], Icons.lock, onClose)
        !hasSnapshot && failed -> UnavailableScreen(s[R.string.zc_state_load_failed], Icons.wifi, onClose, onRetry = engineRetry)
        !hasSnapshot || navigator == null || snapshot == null -> SkeletonScreen(onClose)
        else -> {
            val stack by navigator.stack.collectAsState()
            val top = stack.last()
            val depth = stack.size
            AnimatedContent(
                targetState = top to depth,
                transitionSpec = {
                    if (env.reducedMotion) {
                        fadeIn(tween(0)) togetherWith fadeOut(tween(0))
                    } else {
                        val forward = targetState.second >= initialState.second
                        val sign = (if (forward) 1 else -1) * (if (env.rtl) -1 else 1)
                        (slideInHorizontally(tween(260)) { w -> sign * w / 4 } + fadeIn(tween(220))) togetherWith
                            (slideOutHorizontally(tween(260)) { w -> -sign * w / 4 } + fadeOut(tween(160)))
                    }
                },
                label = "route",
                modifier = Modifier.fillMaxSize().background(env.colors.bg),
            ) { (route, _) ->
                Box(Modifier.fillMaxSize().background(env.colors.bg)) {
                    when (route) {
                        Route.Home -> HomeScreen(navigator, snapshot, onClose)
                        Route.ConversationList -> ConversationListScreen(navigator, onClose)
                        is Route.Thread -> ThreadScreen(navigator, route, snapshot, onClose)
                    }
                }
            }

            if (env.engine.gate() == Gate.NEEDS_CONSENT && accepted != snapshot.behavior.consentTerms) {
                ConsentSheet(
                    text = snapshot.behavior.consentText.pick(env.locale) ?: s[R.string.zc_consent_default],
                    privacyUrl = snapshot.behavior.privacyUrl.takeIf { it.isNotBlank() },
                    onAccept = env.engine::acceptConsent,
                    onDecline = onClose,
                )
            }
            if (viewer != null) ViewerScreen(viewer, navigator::closeViewer)
        }
    }
}
