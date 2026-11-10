package ai.zellio.chat.internal.ui

import ai.zellio.chat.R
import ai.zellio.chat.internal.core.Gate
import ai.zellio.chat.internal.core.OutboxAttachment
import ai.zellio.chat.internal.core.Snapshot
import ai.zellio.chat.internal.core.TimelineRow
import ai.zellio.chat.internal.core.UiAttachment
import ai.zellio.chat.internal.engine.ChatNavigator
import ai.zellio.chat.internal.engine.Connection
import ai.zellio.chat.internal.engine.LoadState
import ai.zellio.chat.internal.engine.Route
import ai.zellio.chat.internal.engine.ViewerState
import ai.zellio.chat.internal.platform.AttachmentImport
import ai.zellio.chat.internal.platform.ImportResult
import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

private const val MAX_PENDING = 4

@Composable
internal fun ThreadScreen(navigator: ChatNavigator, route: Route.Thread, snapshot: Snapshot, onClose: () -> Unit) {
    val env = chatEnv
    val c = env.colors
    val s = env.strings
    val engine = env.engine
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val gate by rememberGate()
    val conversations by engine.conversations.collectAsState()
    val connection by engine.connection.collectAsState()
    val reconnecting by engine.showReconnecting.collectAsState()
    val rateLimited by engine.isRateLimited.collectAsState()
    val config by engine.config.collectAsState()
    val attachDisabled by engine.attachDisabledByServer.collectAsState()

    // "Open the current conversation": find the open one (or none: a new one) once the session exists.
    var resolving by remember(route) { mutableStateOf(route.resolveLatest) }
    LaunchedEffect(route, gate) {
        if (!route.resolveLatest || gate != Gate.OPEN) return@LaunchedEffect
        val ok = engine.ensureSession()
        if (ok) engine.loadConversations()
        val target = engine.conversations.value.items.firstOrNull { it.status == "open" || it.status == null }?.id
        resolving = false
        if (ok || target != null) navigator.replaceTop(Route.Thread(target))
        else navigator.replaceTop(Route.Thread(null))
    }

    val controller = remember(route.id) { engine.thread(route.id) }
    DisposableEffect(controller) { onDispose { controller.close() } }
    LaunchedEffect(controller, gate, route.resolveLatest) {
        if (!route.resolveLatest && gate == Gate.OPEN) controller.open()
    }
    // Visible only while the screen is resumed: that is when a new reply counts as read.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, controller) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> controller.setVisible(true)
                Lifecycle.Event.ON_PAUSE -> controller.setVisible(false)
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) controller.setVisible(true)
        onDispose { lifecycle.removeObserver(observer); controller.setVisible(false) }
    }

    val ui by controller.ui.collectAsState()
    val online = config?.availability?.online ?: true

    // ---- attachments ----
    val pending = remember { mutableStateListOf<OutboxAttachment>() }
    var notice by remember { mutableStateOf<ComposerNotice?>(null) }
    var sheet by remember { mutableStateOf(false) }
    var copied by remember { mutableStateOf(false) }
    val storeDir = remember { File(context.noBackupFilesDir, "zellio-chat/outbox-files") }

    LaunchedEffect(notice) {
        if (notice is ComposerNotice.Error) {
            delay(5_000)
            notice = null
        }
    }
    LaunchedEffect(copied) {
        if (copied) {
            delay(1_200)
            copied = false
        }
    }

    fun accept(uri: Uri?) {
        if (uri == null) return
        scope.launch {
            val result = withContext(Dispatchers.IO) { AttachmentImport.import(context, uri, storeDir) }
            when (result) {
                is ImportResult.Ok -> if (pending.size < MAX_PENDING) pending.add(result.attachment)
                ImportResult.TooLarge -> notice = ComposerNotice.Error(s[R.string.zc_attachment_too_large])
                ImportResult.TypeDenied -> notice = ComposerNotice.Error(s[R.string.zc_attachment_type_denied])
                ImportResult.Failed -> notice = ComposerNotice.Error(s[R.string.zc_attachment_failed])
            }
        }
    }

    val photoPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { accept(it) }
    val filePicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { accept(it) }
    var cameraFile by remember { mutableStateOf<File?>(null) }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        val file = cameraFile
        cameraFile = null
        if (ok && file != null) {
            scope.launch {
                val result = withContext(Dispatchers.IO) {
                    AttachmentImport.import(context, Uri.fromFile(file), storeDir, knownMime = "image/jpeg").also { file.delete() }
                }
                when (result) {
                    is ImportResult.Ok -> if (pending.size < MAX_PENDING) pending.add(result.attachment)
                    ImportResult.TooLarge -> notice = ComposerNotice.Error(s[R.string.zc_attachment_too_large])
                    else -> notice = ComposerNotice.Error(s[R.string.zc_attachment_failed])
                }
            }
        } else file?.delete()
    }

    fun launchCamera() {
        val dir = File(context.cacheDir, "zellio-camera").also { it.mkdirs() }
        val file = File(dir, UUID.randomUUID().toString() + ".jpg")
        cameraFile = file
        val uri = FileProvider.getUriForFile(context, context.packageName + ".zellio.fileprovider", file)
        camera.launch(uri)
    }

    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) launchCamera() else notice = ComposerNotice.CameraDenied
    }

    fun onCameraTapped() {
        // The permission is asked only now, on tap, and only if the host app declares it (the SDK does not).
        if (hostDeclaresCamera(context) && ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            cameraPermission.launch(Manifest.permission.CAMERA)
        } else {
            launchCamera()
        }
    }

    val actions = remember(controller) {
        BubbleActions(
            onRetry = { engine.retry(it) },
            onCancelUpload = { engine.cancelSend(it) },
            onOpenImage = { att: UiAttachment -> navigator.openViewer(ViewerState(att.url, att.localPath, att.name)) },
            onCopy = { text ->
                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                cm?.setPrimaryClip(ClipData.newPlainText("message", text))
                copied = true
            },
            onExpiredUrl = { scope.launch { controller.reloadExpiredUrls() } },
        )
    }

    // ---- list state ----
    val listState = rememberLazyListState()
    val rows = ui.rows
    val seen = remember { HashSet<String>() }
    var initialDone by remember { mutableStateOf(false) }
    var previousCount by remember { mutableStateOf(0) }
    var unseenBelow by remember { mutableStateOf(false) }
    val newestKey = rows.lastOrNull()?.key
    val newestFromVisitor = (rows.lastOrNull() as? TimelineRow.Message)?.message?.fromVisitor == true
    LaunchedEffect(newestKey, ui.typing) {
        val added = rows.size - previousCount
        previousCount = rows.size
        if (!initialDone) {
            if (rows.isNotEmpty() || ui.load == LoadState.READY) initialDone = true
            return@LaunchedEffect
        }
        if (added <= 0) return@LaunchedEffect
        val atBottom = listState.firstVisibleItemIndex <= added + (if (ui.typing) 1 else 0)
        if (newestFromVisitor || atBottom) {
            if (env.reducedMotion) listState.scrollToItem(0) else listState.animateScrollToItem(0)
            unseenBelow = false
        } else {
            unseenBelow = true
        }
    }
    val atBottomNow by remember { derivedStateOf { listState.firstVisibleItemIndex == 0 } }
    LaunchedEffect(atBottomNow) { if (atBottomNow) unseenBelow = false }
    // Older messages load when the top of the list is near.
    LaunchedEffect(listState, ui.hasOlder) {
        snapshotFlow { listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index to listState.layoutInfo.totalItemsCount }
            .collect { (last, total) -> if (ui.hasOlder && last != null && last >= total - 3) controller.loadOlder() }
    }

    Box(Modifier.fillMaxSize().background(c.bg)) {
        Column(Modifier.fillMaxSize()) {
            ThreadTopBar(
                title = ui.agent?.name ?: env.brandName,
                online = online,
                subtitle = if (online) snapshot.behavior.replyExpectation.text(env.locale) ?: s[R.string.zc_banner_online] else s[R.string.zc_banner_outside_hours],
                canGoBack = navigator.canPop,
                onBack = { navigator.back() },
                onClose = onClose,
            )
            if (reconnecting && connection == Connection.RECONNECTING) {
                BannerBar(s[R.string.zc_banner_reconnecting], warn = true, icon = Icons.wifi, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
            }
            if (rateLimited) BannerBar(s[R.string.zc_state_rate_limited], warn = true, icon = Icons.alert)
            Box(Modifier.weight(1f).fillMaxWidth()) {
                when {
                    resolving || (ui.load == LoadState.LOADING && rows.isEmpty() && route.id != null) -> ThreadSkeleton()
                    ui.load == LoadState.FAILED && rows.isEmpty() -> RetryState(s[R.string.zc_state_load_failed]) {
                        scope.launch { controller.retryLoad() }
                    }
                    else -> MessageList(
                        rows = rows,
                        listState = listState,
                        seen = seen,
                        initialDone = initialDone,
                        ui = ui,
                        actions = actions,
                        awayNote = if (!online) snapshot.screens.offline.text(env.locale) ?: s[R.string.zc_banner_offline] else null,
                        greeting = if (rows.isEmpty()) snapshot.screens.greeting.text(env.locale) ?: s[R.string.zc_thread_greeting] else null,
                    )
                }
                NewMessageHost(
                    visible = unseenBelow,
                    modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 10.dp),
                ) {
                    scope.launch { if (env.reducedMotion) listState.scrollToItem(0) else listState.animateScrollToItem(0) }
                }
                if (copied) CopiedPill(Modifier.align(Alignment.TopCenter).padding(top = 10.dp))
            }
            val allowAttach = engine.attachAllowed() && !attachDisabled
            Composer(
                draftKey = controller.draftKey(),
                allowAttach = allowAttach,
                pending = pending,
                notice = notice,
                onRemovePending = { a -> pending.remove(a); File(a.path).delete() },
                onAttach = { if (pending.size < MAX_PENDING) sheet = true },
                onOpenSettings = {
                    context.startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + context.packageName)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                },
                onSend = { text ->
                    val files = pending.toList()
                    pending.clear()
                    notice = null
                    controller.send(text, files)
                    scope.launch { listState.scrollToItem(0) }
                },
            )
        }
        AnimatedVisibility(visible = sheet, enter = fadeIn(), exit = fadeOut()) {
            AttachSheet(
                onCamera = { sheet = false; onCameraTapped() },
                onPhotos = { sheet = false; photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                onFiles = { sheet = false; filePicker.launch(arrayOf("application/pdf", "image/*")) },
                onDismiss = { sheet = false },
            )
        }
        BackHandler(enabled = sheet) { sheet = false }
    }
}

@Composable
private fun rememberGate(): androidx.compose.runtime.State<Gate> {
    val env = chatEnv
    val config by env.engine.config.collectAsState()
    val accepted by env.engine.acceptedTerms.collectAsState()
    return remember(config, accepted) { mutableStateOf(env.engine.gate()) }
}

private fun hostDeclaresCamera(context: Context): Boolean = try {
    val info = if (android.os.Build.VERSION.SDK_INT >= 33) {
        context.packageManager.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(PackageManager.GET_PERMISSIONS.toLong()))
    } else {
        @Suppress("DEPRECATION")
        context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
    }
    info.requestedPermissions?.contains(Manifest.permission.CAMERA) == true
} catch (_: Throwable) {
    false
}

@Composable
private fun ThreadTopBar(title: String, online: Boolean, subtitle: String, canGoBack: Boolean, onBack: () -> Unit, onClose: () -> Unit) {
    val env = chatEnv
    val c = env.colors
    val s = env.strings
    Column(Modifier.fillMaxWidth().background(c.bg)) {
        Row(
            Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).padding(start = 4.dp, end = 4.dp, top = 2.dp, bottom = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (canGoBack) ChatIconButton(s[R.string.zc_common_back], Icons.back, c.ink, onBack, mirror = true) else Box(Modifier.size(12.dp))
            Logo(32.dp, 10.dp, onHeader = false)
            Column(Modifier.weight(1f).padding(horizontal = 10.dp)) {
                ChatText(title, Roles.SCREEN_TITLE, FontWeight.SemiBold, maxLines = 1, modifier = Modifier.semantics { heading() })
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    if (online) Dot(c.ok, 7.dp)
                    ChatText(subtitle, 12.5f, color = c.ink2, maxLines = 1)
                }
            }
            ChatIconButton(s[R.string.zc_common_close], Icons.close, c.ink2, onClose)
        }
        Box(Modifier.fillMaxWidth().size(1.dp).background(c.line))
    }
}

@Composable
private fun MessageList(
    rows: List<TimelineRow>,
    listState: androidx.compose.foundation.lazy.LazyListState,
    seen: MutableSet<String>,
    initialDone: Boolean,
    ui: ai.zellio.chat.internal.engine.ThreadUi,
    actions: BubbleActions,
    awayNote: String?,
    greeting: String?,
) {
    val env = chatEnv
    val c = env.colors
    // The newest row is index 0 (reverse layout): the list stays at the bottom when the keyboard opens, and
    // older pages added at the top never move what the reader sees.
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        state = listState,
        reverseLayout = true,
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 12.dp),
    ) {
        if (awayNote != null) {
            item(key = "away") {
                ChatText(
                    awayNote, 13.5f, color = c.ink2,
                    modifier = Modifier.padding(top = 14.dp).fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(c.bgAlt).padding(horizontal = 14.dp, vertical = 12.dp),
                )
            }
        }
        if (ui.typing) {
            item(key = "typing") { TypingBubble(ui.agent, ui.typingName) }
        }
        items(rows.asReversed(), key = { it.key }) { row ->
            val animate = initialDone && seen.add(row.key)
            if (!initialDone) seen.add(row.key)
            AppearOnce(animate) {
                when (row) {
                    is TimelineRow.DateSeparator -> DateSeparator(row)
                    is TimelineRow.Message -> MessageItem(row, ui.agent, actions)
                }
            }
        }
        if (ui.loadingOlder) {
            item(key = "older") {
                ChatText(
                    env.strings[R.string.zc_thread_loading_older], Roles.TIME, color = c.ink2,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp),
                    align = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }
        }
        if (greeting != null) {
            item(key = "greeting") {
                ChatText(
                    greeting, 15f, color = c.ink2,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp, horizontal = 12.dp),
                    align = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }
        }
    }
}

/** Outside any Column or Row scope, so the plain AnimatedVisibility is the one that is picked. */
@Composable
private fun NewMessageHost(visible: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val env = chatEnv
    AnimatedVisibility(
        visible = visible,
        modifier = modifier,
        enter = if (env.reducedMotion) fadeIn() else fadeIn() + slideInVertically { it / 2 },
        exit = fadeOut() + if (env.reducedMotion) slideOutVertically { 0 } else slideOutVertically { it / 2 },
    ) { NewMessagePill(onClick) }
}

@Composable
private fun NewMessagePill(onClick: () -> Unit) {
    val env = chatEnv
    val c = env.colors
    val shape = RoundedCornerShape(22.dp)
    Row(
        Modifier.shadow(6.dp, shape).clip(shape).background(c.primary).clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 11.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        ChatText(env.strings[R.string.zc_thread_new_message], 14f, FontWeight.SemiBold, c.onPrimary)
        Icon(Icons.send, c.onPrimary, 16.dp, modifier = Modifier.rotate(180f))
    }
}

