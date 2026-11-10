package ai.zellio.chat.internal.ui

import ai.zellio.chat.R
import ai.zellio.chat.internal.core.ChatLocale
import ai.zellio.chat.internal.core.ConversationSummary
import ai.zellio.chat.internal.core.DateLabels
import ai.zellio.chat.internal.core.Decoders
import ai.zellio.chat.internal.core.HomeModule
import ai.zellio.chat.internal.core.LocalizedText
import ai.zellio.chat.internal.core.ModuleVisibility
import ai.zellio.chat.internal.core.Snapshot
import ai.zellio.chat.internal.engine.ChatNavigator
import ai.zellio.chat.internal.engine.Route
import ai.zellio.chat.internal.platform.AndroidEnv
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

internal fun LocalizedText?.text(locale: ChatLocale): String? = this?.pick(locale)

/** The time label of a conversation row: the time today, "Yesterday", else the date. */
internal fun conversationTime(ms: Long, locale: ChatLocale, strings: Strings, now: Long = System.currentTimeMillis()): String {
    if (ms <= 0) return ""
    return when (DateLabels.dayKind(ms, now, java.util.TimeZone.getDefault())) {
        DateLabels.Kind.TODAY -> DateLabels.time(ms, locale)
        DateLabels.Kind.YESTERDAY -> strings[R.string.zc_thread_yesterday]
        DateLabels.Kind.DATE -> DateLabels.date(ms, locale, now)
    }
}

@Composable
internal fun HomeScreen(navigator: ChatNavigator, snapshot: Snapshot, onClose: () -> Unit) {
    val env = chatEnv
    val c = env.colors
    val s = env.strings
    val engine = env.engine
    val config by engine.config.collectAsState()
    val session by engine.session.collectAsState()
    val conversations by engine.conversations.collectAsState()
    val acceptedTerms by engine.acceptedTerms.collectAsState()
    val context = LocalContext.current

    // The recent list needs a session: it only loads when there already is one (never starts one from a saved config).
    LaunchedEffect(session != null, acceptedTerms, config?.snapshot?.versionId) {
        if (session != null && engine.gate() == ai.zellio.chat.internal.core.Gate.OPEN) engine.loadConversations()
    }

    val online = config?.availability?.online ?: true
    val identified = session?.identified ?: false
    val modules = remember(snapshot.modules) { Decoders.modules(snapshot.modules) }
    val visible = modules.filter { ModuleVisibility.visible(it, env.locale, online, identified) }

    fun startConversation() {
        // Continue the open conversation if there is one, else start a new one.
        navigator.push(Route.Thread(null, resolveLatest = true))
    }

    Column(Modifier.fillMaxSize().background(c.bg)) {
        // Header: under the status bar, brand gradient (or solid, or light).
        Column(
            Modifier.fillMaxWidth().chatHeaderBackground(c, env.rtl)
                .windowInsetsPadding(WindowInsets.statusBars)
                // The tablet card has no status bar above the header.
                .padding(start = 20.dp, end = 12.dp, top = if (LocalConfiguration.current.screenWidthDp >= 600) 18.dp else 8.dp, bottom = 40.dp),
        ) {
            Row(Modifier.fillMaxWidth().padding(end = 0.dp), verticalAlignment = Alignment.CenterVertically) {
                Logo(40.dp, 12.dp, onHeader = true)
                Box(Modifier.weight(1f))
                ChatIconButton(s[R.string.zc_common_close], Icons.close, c.onHeader, onClose, background = c.onHeader.copy(alpha = 0.14f))
            }
            Box(Modifier.size(14.dp))
            ChatText(
                snapshot.screens.heading.text(env.locale) ?: s[R.string.zc_home_fallback_heading],
                Roles.HOME_HEADING, FontWeight.Bold, c.onHeader,
                Modifier.padding(end = 8.dp).semantics { heading() },
            )
            Box(Modifier.size(6.dp))
            snapshot.screens.description.text(env.locale)?.let {
                ChatText(it, 15f, FontWeight.Normal, c.onHeader, Modifier.alpha(0.92f).padding(end = 8.dp))
            }
            Row(Modifier.padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Dot(Color(if (online) 0xFF4ADE80 else 0xFFFBBF24), 8.dp)
                ChatText(
                    if (online) snapshot.behavior.replyExpectation.text(env.locale) ?: s[R.string.zc_banner_online] else s[R.string.zc_banner_outside_hours],
                    Roles.SECONDARY, FontWeight.Medium, c.onHeader,
                )
            }
        }
        // Body: scrolls over the header's lower edge by 20 dp.
        Column(
            Modifier.weight(1f).fillMaxWidth()
                .layout { measurable, constraints ->
                    val overlap = 20.dp.roundToPx()
                    val placeable = measurable.measure(constraints.copy(maxHeight = constraints.maxHeight + overlap, minHeight = constraints.maxHeight + overlap))
                    layout(placeable.width, placeable.height - overlap) { placeable.place(0, -overlap) }
                }
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Box(Modifier.size(0.dp))
            ModuleList(visible, snapshot, ::startConversation, onLink = { AndroidEnv.openLink(context, it) })
            if (session != null && conversations.items.isNotEmpty()) {
                Row(
                    Modifier.fillMaxWidth().padding(top = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    ChatText(s[R.string.zc_home_recent], Roles.SECTION, FontWeight.SemiBold, modifier = Modifier.semantics { heading() })
                    ChatText(
                        s[R.string.zc_home_see_all], 14f, FontWeight.Medium, c.link,
                        Modifier.heightIn(min = 48.dp).clickable(role = Role.Button) { navigator.push(Route.ConversationList) }.padding(vertical = 14.dp),
                    )
                }
                Column(Modifier.fillMaxWidth().chatCard(c)) {
                    conversations.items.take(3).forEachIndexed { i, item ->
                        if (i > 0) Box(Modifier.fillMaxWidth().size(1.dp).background(c.line))
                        ConversationRow(item, compact = true) { navigator.push(Route.Thread(item.id)) }
                    }
                }
            }
            if (snapshot.appearance.showAttribution) Attribution()
            Box(Modifier.windowInsetsPadding(WindowInsets.navigationBars).size(8.dp))
        }
    }
}

@Composable
internal fun Attribution() {
    ChatText(
        chatEnv.strings[R.string.zc_common_powered_by], Roles.TIME, color = chatEnv.colors.ink2,
        modifier = Modifier.fillMaxWidth().padding(vertical = 14.dp), align = TextAlign.Center,
    )
}

@Composable
private fun ModuleList(modules: List<HomeModule>, snapshot: Snapshot, onStart: () -> Unit, onLink: (String) -> Unit) {
    val env = chatEnv
    val c = env.colors
    val s = env.strings
    // Actions that follow each other share one card, as on the canvas. Other modules are cards of their own.
    val groups = mutableListOf<MutableList<HomeModule>>()
    for (m in modules) {
        val action = m is HomeModule.StartConversation || m is HomeModule.ExternalLink || m is HomeModule.ContactLinks
        if (action && groups.lastOrNull()?.firstOrNull()?.let { it is HomeModule.StartConversation || it is HomeModule.ExternalLink || it is HomeModule.ContactLinks } == true) {
            groups.last().add(m)
        } else {
            groups.add(mutableListOf(m))
        }
    }
    for (group in groups) {
        val first = group.first()
        if (first is HomeModule.Greeting || first is HomeModule.Announcement) {
            val (label, description) = when (first) {
                is HomeModule.Greeting -> first.label to first.description
                is HomeModule.Announcement -> first.label to first.description
                else -> return
            }
            val title = label.text(env.locale)
            val body = description.text(env.locale) ?: if (first is HomeModule.Greeting) snapshot.screens.greeting.text(env.locale) else null
            if (title == null && body == null) continue
            Column(Modifier.fillMaxWidth().chatCard(c).padding(horizontal = 16.dp, vertical = 14.dp)) {
                if (title != null) ChatText(title, Roles.SECTION, FontWeight.SemiBold)
                if (title != null && body != null) Box(Modifier.size(3.dp))
                if (body != null) ChatText(body, 14f, color = c.ink2)
            }
            continue
        }
        Column(Modifier.fillMaxWidth().chatCard(c)) {
            var index = 0
            for (m in group) {
                when (m) {
                    is HomeModule.StartConversation -> {
                        val label = m.label.text(env.locale) ?: s[R.string.zc_home_talk_to_team]
                        if (m.primary) {
                            Box(Modifier.fillMaxWidth().padding(14.dp)) {
                                FilledButton(label, onStart, Modifier.fillMaxWidth(), icon = Icons.chat)
                            }
                        } else {
                            ActionRow(Icons.chat, label, onStart)
                        }
                    }
                    is HomeModule.ExternalLink -> {
                        if (index > 0) Divider()
                        ActionRow(Icons.link, m.label.text(env.locale) ?: m.href) { onLink(m.href) }
                    }
                    is HomeModule.ContactLinks -> m.links.forEach { link ->
                        if (index > 0) Divider()
                        ActionRow(Icons.link, link.label.text(env.locale) ?: link.href) { onLink(link.href) }
                        index++
                    }
                    else -> Unit
                }
                index++
            }
        }
    }
}

@Composable
private fun Divider() {
    Box(Modifier.fillMaxWidth().size(1.dp).background(chatEnv.colors.line))
}

@Composable
private fun ActionRow(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    val c = chatEnv.colors
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(role = Role.Button, onClick = onClick).padding(horizontal = 14.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.size(36.dp).clip(RoundedCornerShape(11.dp)).background(c.bgAlt), contentAlignment = Alignment.Center) {
            Icon(icon, c.ink2, 19.dp)
        }
        ChatText(label, 15.5f, FontWeight.Medium, modifier = Modifier.weight(1f))
        Icon(Icons.forward, c.ink2, 17.dp, mirror = true)
    }
}

/** One row of a conversation: avatar, name, last message in one line, time, unread dot. */
@Composable
internal fun ConversationRow(item: ConversationSummary, compact: Boolean, onClick: () -> Unit) {
    val env = chatEnv
    val c = env.colors
    val s = env.strings
    val name = item.agentName ?: env.brandName
    val unread = item.unread > 0
    val textColor = if (unread) c.ink else c.ink2
    val preview = when {
        item.lastText.isNotBlank() -> item.lastText.replace('\n', ' ')
        item.lastHasAttachment -> if (item.lastAttachmentKind == "image") s[R.string.zc_attachment_photo] else s[R.string.zc_attachment_file]
        else -> ""
    }
    val time = conversationTime(item.lastMessageAtMs, env.locale, s)
    val unreadLabel = s[R.string.zc_a11y_unread]
    Row(
        Modifier.fillMaxWidth().heightIn(min = if (compact) 64.dp else 72.dp)
            .semantics(mergeDescendants = true) { if (unread) contentDescription = "$name, $preview, $time, $unreadLabel" }
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = if (compact) 14.dp else 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(if (compact) 12.dp else 13.dp),
    ) {
        Avatar(name, item.agentAvatarUrl, if (compact) 36.dp else 44.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            ChatText(name, if (compact) 15f else 16f, FontWeight.SemiBold, maxLines = 1)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                if (item.lastText.isBlank() && item.lastHasAttachment) Icon(Icons.clip, textColor, 15.dp, mirror = true)
                ChatText(preview, if (compact) 13.5f else 14f, if (unread) FontWeight.Medium else FontWeight.Normal, textColor, Modifier.weight(1f, fill = false), maxLines = 1, content = true)
            }
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            ChatText(time, Roles.TIME, color = c.ink2, maxLines = 1)
            if (unread) Dot(c.primary, if (compact) 9.dp else 10.dp) else Box(Modifier.size(if (compact) 9.dp else 10.dp))
        }
    }
}
