package ai.zellio.chat.internal.ui

import ai.zellio.chat.R
import ai.zellio.chat.internal.core.DateLabels
import ai.zellio.chat.internal.core.Delivery
import ai.zellio.chat.internal.core.LinkDetector
import ai.zellio.chat.internal.core.TimelineRow
import ai.zellio.chat.internal.core.UiAttachment
import ai.zellio.chat.internal.engine.AgentInfo
import ai.zellio.chat.internal.platform.AndroidEnv
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.keyframes
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.ParagraphStyle
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.text.BasicText

internal class BubbleActions(
    val onRetry: (String) -> Unit,
    val onCancelUpload: (String) -> Unit,
    val onOpenImage: (UiAttachment) -> Unit,
    val onCopy: (String) -> Unit,
    val onExpiredUrl: () -> Unit,
)

internal fun fileSize(bytes: Long): String = when {
    bytes <= 0 -> ""
    bytes < 1024 * 1024 -> "${maxOf(1L, bytes / 1024)} KB"
    else -> "%.1f MB".format(java.util.Locale.ROOT, bytes / 1024.0 / 1024.0)
}

/** The centered date label between days: Today, Yesterday, or a date. */
@Composable
internal fun DateSeparator(row: TimelineRow.DateSeparator) {
    val env = chatEnv
    val text = when (row.kind) {
        DateLabels.Kind.TODAY -> env.strings[R.string.zc_thread_today]
        DateLabels.Kind.YESTERDAY -> env.strings[R.string.zc_thread_yesterday]
        DateLabels.Kind.DATE -> DateLabels.date(row.ms, env.locale, System.currentTimeMillis())
    }
    Box(Modifier.padding(vertical = 6.dp).fillMaxWidth(), contentAlignment = Alignment.Center) {
        ChatText(text, Roles.TIME, FontWeight.Medium, env.colors.ink2, Modifier.padding(horizontal = 12.dp, vertical = 6.dp))
    }
}

/** A new item slides up 8 dp and fades in over 180 ms (fade only with reduced motion). */
@Composable
internal fun AppearOnce(animate: Boolean, content: @Composable () -> Unit) {
    val env = chatEnv
    if (!animate) {
        content()
        return
    }
    val progress = remember { Animatable(0f) }
    LaunchedEffect(Unit) { progress.animateTo(1f, tween(if (env.reducedMotion) 120 else 180, easing = FastOutSlowInEasing)) }
    Box(
        Modifier.graphicsLayer {
            alpha = progress.value
            if (!env.reducedMotion) translationY = (1f - progress.value) * 8.dp.toPx()
        },
    ) { content() }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun MessageItem(row: TimelineRow.Message, agent: AgentInfo?, actions: BubbleActions) {
    val env = chatEnv
    val c = env.colors
    val s = env.strings
    val m = row.message
    val mine = m.fromVisitor
    val shapes = env.shapes
    val r = shapes.bubbleRadius.dp
    val tail = shapes.tailRadius.dp
    val shape = if (mine) {
        RoundedCornerShape(topStart = r, topEnd = r, bottomEnd = if (row.last) tail else r, bottomStart = r)
    } else {
        RoundedCornerShape(topStart = r, topEnd = r, bottomEnd = r, bottomStart = if (row.last) tail else r)
    }
    val topGap = if (row.first) shapes.newSenderGap.dp else shapes.groupedGap.dp
    val context = LocalContext.current
    val senderName = if (mine) s[R.string.zc_a11y_you] else (m.agentName ?: agent?.name ?: s[R.string.zc_a11y_team])
    val time = DateLabels.time(m.timeMs, env.locale)
    val deliveryText = when (row.delivery) {
        Delivery.SENDING -> s[R.string.zc_delivery_sending]
        Delivery.SENT -> s[R.string.zc_delivery_sent]
        Delivery.QUEUED -> s[R.string.zc_delivery_waiting]
        Delivery.FAILED -> s[R.string.zc_delivery_failed]
        Delivery.NONE -> null
    }
    val body = m.text.ifBlank {
        m.attachments.joinToString(", ") { if (it.isImage) s[R.string.zc_attachment_photo] else it.name.ifBlank { s[R.string.zc_attachment_file] } }
    }
    val spoken = listOfNotNull(senderName, body, time, deliveryText).joinToString(", ")
    val hasImage = m.attachments.any { it.isImage }

    Column(Modifier.padding(top = topGap).fillMaxWidth()) {
        if (row.showName) {
            ChatText(
                m.agentName.orEmpty(), 12.5f, FontWeight.Medium, c.ink2,
                Modifier.padding(start = 36.dp, bottom = 4.dp).clearAndSetSemantics { },
            )
        }
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val maxBubble = minOf(maxWidth * 0.78f, 520.dp)
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start,
                verticalAlignment = Alignment.Bottom,
            ) {
                if (!mine) {
                    if (env.showAvatars && row.last) Avatar(m.agentName ?: agent?.name, m.agentAvatarUrl ?: agent?.avatarUrl, 28.dp)
                    else Box(Modifier.size(28.dp))
                    Box(Modifier.width(8.dp))
                }
                val bubbleModifier = Modifier
                    .then(if (hasImage) Modifier.width(minOf(IMAGE_WIDTH, maxBubble)) else Modifier.widthIn(max = maxBubble))
                    .clip(shape)
                    .background(if (mine) c.customer else c.agentBubble)
                    .semantics { contentDescription = spoken }
                    .combinedClickable(
                        onClick = {},
                        onLongClick = { if (m.text.isNotBlank()) actions.onCopy(m.text) },
                        onLongClickLabel = s[R.string.zc_common_copy],
                    )
                Column(bubbleModifier) {
                    m.attachments.forEach { att ->
                        if (att.isImage) ImageAttachment(att, mine, actions)
                        else FileAttachment(att, mine)
                    }
                    if (m.text.isNotBlank()) {
                        MessageText(m.text, mine, Modifier.padding(horizontal = 14.dp, vertical = 9.dp)) { AndroidEnv.openLink(context, it) }
                    }
                }
            }
        }
        DeliveryLine(row, m.clientMessageId, actions)
    }
}

private val IMAGE_WIDTH = 240.dp

@Composable
private fun MessageText(text: String, mine: Boolean, modifier: Modifier, onLink: (String) -> Unit) {
    val env = chatEnv
    val c = env.colors
    val linkColor = if (mine) c.onCustomer else c.link
    val style = env.type.style(Roles.MESSAGE, FontWeight.Normal, if (mine) c.onCustomer else c.ink)
    val annotated = remember(text, mine, linkColor) {
        buildAnnotatedString {
            val spans = LinkDetector.find(text)
            val paragraphs = text.split('\n')
            var offset = 0
            paragraphs.forEachIndexed { index, paragraph ->
                // Each paragraph takes the natural direction of its own text (Arabic and English can mix).
                withStyleParagraph(paragraph, offset, spans, linkColor, onLink)
                if (index < paragraphs.lastIndex) append("\n")
                offset += paragraph.length + 1
            }
        }
    }
    BasicText(annotated, modifier = modifier, style = style.copy(textDirection = TextDirection.Content))
}

private fun AnnotatedString.Builder.withStyleParagraph(
    paragraph: String,
    offset: Int,
    spans: List<LinkDetector.Span>,
    linkColor: Color,
    onLink: (String) -> Unit,
) {
    pushStyle(ParagraphStyle(textDirection = TextDirection.Content))
    var cursor = 0
    for (span in spans) {
        val start = span.start - offset
        val end = span.end - offset
        if (start < 0 || end > paragraph.length || start < cursor) continue
        append(paragraph.substring(cursor, start))
        withLink(
            LinkAnnotation.Clickable(
                tag = span.url,
                styles = TextLinkStyles(SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline)),
                linkInteractionListener = { onLink(span.url) },
            ),
        ) { append(paragraph.substring(start, end)) }
        cursor = end
    }
    append(paragraph.substring(cursor))
    pop()
}

/** A photo fills the bubble edge to edge (the bubble clips it). The placeholder has the real size when it is known. */
@Composable
private fun ImageAttachment(att: UiAttachment, mine: Boolean, actions: BubbleActions) {
    val env = chatEnv
    val c = env.colors
    val s = env.strings
    val key = att.url ?: att.localPath
    val aspect = (key?.let { env.images.knownAspect(it) } ?: att.localPath?.let { env.images.aspectOfFile(it) } ?: (4f / 3f)).coerceIn(0.6f, 1.8f)
    var attempt by remember { mutableIntStateOf(0) }
    val image by rememberImage(att.url, att.localPath, 720, attempt, onForbidden = actions.onExpiredUrl)
    val failed = image is ImageState.Failed
    val label = s[R.string.zc_attachment_photo]
    val uploading = att.progress != null
    val clientId = att.key.substringBefore('#')
    Box(
        Modifier.fillMaxWidth().aspectRatio(aspect).background(if (c.dark) Color(0xFF273050) else Color(0x14111426))
            .semantics { contentDescription = label }
            .clickable(role = Role.Button, enabled = !uploading) { if (failed) attempt++ else actions.onOpenImage(att) },
    ) {
        when (val state = image) {
            is ImageState.Loaded -> BitmapImage(state.bitmap, Modifier.fillMaxWidth().aspectRatio(aspect), ContentScale.Crop)
            // The box keeps its size in every state, so nothing jumps when the photo arrives or fails.
            ImageState.Failed -> Column(
                Modifier.align(Alignment.Center).padding(12.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(Icons.image, if (mine) c.onCustomer else c.ink2, 28.dp)
                ChatText(s[R.string.zc_state_retry], 13f, FontWeight.Medium, if (mine) c.onCustomer else c.ink2)
            }
            ImageState.Loading -> Unit
        }
        if (uploading) UploadRing(att.progress ?: 0f, s[R.string.zc_attachment_cancel]) { actions.onCancelUpload(clientId) }
    }
}

/** A ring over the image while it uploads. Tap cancels. */
@Composable
private fun BoxScope.UploadRing(progress: Float, label: String, onCancel: () -> Unit) {
    Box(
        Modifier.align(Alignment.Center).size(48.dp).semantics { contentDescription = label }
            .clickable(role = Role.Button, onClick = onCancel),
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.size(44.dp).clip(CircleShape).background(Color(0x8C090D28)), contentAlignment = Alignment.Center) {
            Canvas(Modifier.size(30.dp)) {
                val stroke = Stroke(width = 3.dp.toPx(), cap = StrokeCap.Round)
                val inset = stroke.width / 2
                val arcSize = Size(size.width - stroke.width, size.height - stroke.width)
                drawCircle(Color.White.copy(alpha = 0.3f), style = stroke, radius = arcSize.width / 2)
                drawArc(Color.White, -90f, 360f * progress.coerceIn(0.04f, 1f), false, Offset(inset, inset), arcSize, style = stroke)
            }
        }
    }
}

@Composable
private fun FileAttachment(att: UiAttachment, mine: Boolean) {
    val env = chatEnv
    val c = env.colors
    val ink = if (mine) c.onCustomer else c.ink
    val sub = if (mine) c.onCustomer.copy(alpha = 0.8f) else c.ink2
    Row(
        Modifier.padding(horizontal = 14.dp, vertical = 9.dp).widthIn(max = 260.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(Modifier.size(40.dp).clip(RoundedCornerShape(11.dp)).background(if (c.dark || mine) Color.White.copy(alpha = 0.16f) else Color.White), contentAlignment = Alignment.Center) {
            Icon(Icons.file, if (mine) c.onCustomer else c.ink2, 20.dp)
        }
        Column {
            // File names and sizes are Latin text: keep them left-to-right.
            BasicText(att.name.ifBlank { env.strings[R.string.zc_attachment_file] }, style = env.type.style(14.5f, FontWeight.Medium, ink).copy(textDirection = TextDirection.Ltr), maxLines = 1)
            val size = fileSize(att.size)
            if (size.isNotEmpty()) BasicText(size, style = env.type.style(12.5f, FontWeight.Normal, sub).copy(textDirection = TextDirection.Ltr))
        }
    }
}

/** The line under a bubble: Sending / Sent / waiting with a clock / Not sent with "Try again". */
@Composable
private fun DeliveryLine(row: TimelineRow.Message, clientMessageId: String?, actions: BubbleActions) {
    val env = chatEnv
    val c = env.colors
    val s = env.strings
    when (row.delivery) {
        Delivery.NONE -> return
        Delivery.FAILED -> Row(
            Modifier.fillMaxWidth().padding(top = 2.dp),
            horizontalArrangement = Arrangement.End,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Icon(Icons.alert, c.bad, 14.dp)
                ChatText(s[R.string.zc_delivery_failed], 12.5f, FontWeight.Medium, c.bad)
            }
            Box(
                Modifier.padding(start = 6.dp).heightIn(min = 48.dp)
                    .clickable(role = Role.Button) { clientMessageId?.let(actions.onRetry) },
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    Modifier.heightIn(min = 36.dp).clip(RoundedCornerShape(18.dp)).border(1.dp, c.line, RoundedCornerShape(18.dp)).padding(horizontal = 14.dp),
                    contentAlignment = Alignment.Center,
                ) { ChatText(s[R.string.zc_delivery_retry], 13.5f, FontWeight.Medium) }
            }
        }
        else -> {
            val text = when (row.delivery) {
                Delivery.SENDING -> s[R.string.zc_delivery_sending]
                Delivery.SENT -> s[R.string.zc_delivery_sent]
                else -> s[R.string.zc_delivery_waiting]
            }
            Row(
                Modifier.fillMaxWidth().padding(top = 4.dp, end = 2.dp).clearAndSetSemantics { },
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (row.delivery == Delivery.QUEUED) {
                    Icon(Icons.clock, c.ink2, 13.dp)
                    Box(Modifier.width(4.dp))
                }
                ChatText(text, Roles.TIME, color = c.ink2)
            }
        }
    }
}

/** Three dots with a slow wave. With reduced motion they are static. */
@Composable
internal fun TypingBubble(agent: AgentInfo?, name: String?) {
    val env = chatEnv
    val c = env.colors
    val label = env.strings[R.string.zc_thread_typing]
    val transition = rememberInfiniteTransition(label = "typing")
    val waves = (0..2).map { i ->
        transition.animateFloat(
            initialValue = 0.35f, targetValue = 0.35f,
            animationSpec = infiniteRepeatable(
                keyframes {
                    durationMillis = 1200
                    0.35f at 0
                    1f at 300
                    0.35f at 600
                    0.35f at 1200
                }, RepeatMode.Restart,
                initialStartOffset = androidx.compose.animation.core.StartOffset(i * 160),
            ),
            label = "dot$i",
        )
    }
    val static = listOf(0.9f, 0.6f, 0.35f)
    val r = env.shapes.bubbleRadius.dp
    Row(
        Modifier.padding(top = env.shapes.newSenderGap.dp).semantics { contentDescription = label; liveRegion = LiveRegionMode.Polite },
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (env.showAvatars) Avatar(name ?: agent?.name, agent?.avatarUrl, 28.dp) else Box(Modifier.size(28.dp))
        Row(
            Modifier.heightIn(min = 38.dp)
                .clip(RoundedCornerShape(topStart = r, topEnd = r, bottomEnd = r, bottomStart = env.shapes.tailRadius.dp))
                .background(c.agentBubble).padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            repeat(3) { i ->
                Box(
                    Modifier.size(7.dp).clip(CircleShape).background(c.ink2)
                        .alpha(if (env.reducedMotion) static[i] else waves[i].value),
                )
            }
        }
    }
}

/** A small "Copied" confirmation. */
@Composable
internal fun CopiedPill(modifier: Modifier = Modifier) {
    val env = chatEnv
    Box(
        modifier.clip(RoundedCornerShape(20.dp)).background(env.colors.ink).padding(horizontal = 16.dp, vertical = 10.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
    ) { ChatText(env.strings[R.string.zc_common_copied], 14f, FontWeight.Medium, env.colors.bg) }
}

