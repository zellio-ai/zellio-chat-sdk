package ai.zellio.chat.internal.ui

import ai.zellio.chat.internal.platform.ImageResult
import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.cos
import kotlin.math.sin

/** A 48 dp touch target around a 44 dp round button, as the canvas shows it. */
@Composable
internal fun ChatIconButton(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    tint: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    mirror: Boolean = false,
    background: Color = Color.Transparent,
) {
    Box(
        modifier = modifier
            .size(48.dp)
            .semantics { contentDescription = label }
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                role = Role.Button,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.size(44.dp).clip(CircleShape).background(background), contentAlignment = Alignment.Center) {
            Icon(icon, tint, 22.dp, mirror = mirror)
        }
    }
}

@Composable
internal fun Dot(color: Color, size: Dp, modifier: Modifier = Modifier) {
    Box(modifier.size(size).clip(CircleShape).background(color))
}

internal sealed interface ImageState {
    data object Loading : ImageState
    data object Failed : ImageState
    data class Loaded(val bitmap: Bitmap) : ImageState
}

/**
 * Image for a remote URL (or a local file): memory cache first, then disk, then network. [attempt] is bumped by the
 * caller to try again after a failure. An expired URL (403) stays [ImageState.Loading] while the thread fetches new URLs.
 */
@Composable
internal fun rememberImage(url: String?, localPath: String?, maxEdge: Int, attempt: Int = 0, onForbidden: (() -> Unit)? = null): State<ImageState> {
    val env = chatEnv
    val cached = url?.let { env.images.cached("$it@$maxEdge") }
    return produceState<ImageState>(initialValue = cached?.let { ImageState.Loaded(it) } ?: ImageState.Loading, url, localPath, maxEdge, attempt) {
        if (value is ImageState.Loaded) return@produceState
        value = ImageState.Loading
        if (localPath != null) {
            value = env.images.loadFile(localPath, maxEdge)?.let { ImageState.Loaded(it) } ?: ImageState.Failed
        } else if (url != null) {
            when (val result = env.images.load(url, maxEdge)) {
                is ImageResult.Loaded -> value = ImageState.Loaded(result.bitmap)
                ImageResult.Forbidden -> onForbidden?.invoke()
                ImageResult.Failed -> value = ImageState.Failed
            }
        } else {
            value = ImageState.Failed
        }
    }
}

/** The bitmap once loaded, null before and after a failure. */
@Composable
internal fun rememberBitmap(url: String?, localPath: String?, maxEdge: Int): State<Bitmap?> {
    val state by rememberImage(url, localPath, maxEdge)
    return rememberUpdatedState((state as? ImageState.Loaded)?.bitmap)
}

@Composable
internal fun BitmapImage(bitmap: Bitmap, modifier: Modifier, scale: ContentScale = ContentScale.Crop) {
    val image = remember(bitmap) { bitmap.asImageBitmap() }
    Image(bitmap = image, contentDescription = null, contentScale = scale, modifier = modifier)
}

/** The brand logo (or a monogram of its first letter). */
@Composable
internal fun Logo(size: Dp, radius: Dp, onHeader: Boolean, modifier: Modifier = Modifier) {
    val env = chatEnv
    val c = env.colors
    val bitmap by rememberBitmap(env.logoUrl, null, 160)
    val shape = RoundedCornerShape(radius)
    val bmp = bitmap
    if (bmp != null) {
        BitmapImage(bmp, modifier.size(size).clip(shape))
    } else {
        val initial = env.brandName.trim().firstOrNull()?.uppercase() ?: "Z"
        Box(
            modifier.size(size).clip(shape).background(if (onHeader) Color.White.copy(alpha = 0.2f) else c.primary),
            contentAlignment = Alignment.Center,
        ) {
            ChatText(initial, size.value * 0.45f, FontWeight.Bold, if (onHeader) c.onHeader else c.onPrimary)
        }
    }
}

@Composable
internal fun Avatar(name: String?, url: String?, size: Dp, modifier: Modifier = Modifier) {
    val env = chatEnv
    val c = env.colors
    val bitmap by rememberBitmap(url, null, 160)
    val bmp = bitmap
    if (bmp != null) {
        BitmapImage(bmp, modifier.size(size).clip(CircleShape))
    } else {
        val initial = (name ?: env.brandName).trim().firstOrNull()?.uppercase() ?: "?"
        Box(
            modifier.size(size).clip(CircleShape).background(if (c.dark) Color(0xFF2B3556) else Color(0xFFD9D3F5)),
            contentAlignment = Alignment.Center,
        ) {
            ChatText(initial, size.value * 0.42f, FontWeight.SemiBold, if (c.dark) Color(0xFFE7E9F6) else Color(0xFF3B2A86))
        }
    }
}

/** A thin bar under the top bar: reconnecting, outside hours. */
@Composable
internal fun BannerBar(text: String, warn: Boolean, icon: androidx.compose.ui.graphics.vector.ImageVector?, modifier: Modifier = Modifier) {
    val c = chatEnv.colors
    val bg = if (warn) c.warnBg else c.bgAlt
    val ink = if (warn) c.warnInk else c.ink2
    Row(
        modifier.fillMaxWidth().background(bg).padding(horizontal = 16.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (icon != null) Icon(icon, ink, 16.dp)
        ChatText(text, Roles.SECONDARY, color = ink, modifier = Modifier.weight(1f))
    }
}

@Composable
internal fun FilledButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    height: Dp = 52.dp,
    radius: Dp = 13.dp,
    icon: androidx.compose.ui.graphics.vector.ImageVector? = null,
    background: Color = chatEnv.colors.primary,
    foreground: Color = chatEnv.colors.onPrimary,
) {
    Row(
        modifier.heightIn(min = height).clip(RoundedCornerShape(radius)).background(background)
            .clickable(role = Role.Button, onClick = onClick).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(9.dp, Alignment.CenterHorizontally),
    ) {
        if (icon != null) Icon(icon, foreground, 20.dp)
        ChatText(text, 16f, FontWeight.SemiBold, foreground, align = androidx.compose.ui.text.style.TextAlign.Center)
    }
}

@Composable
internal fun OutlinedButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    height: Dp = 48.dp,
    radius: Dp = 13.dp,
    size: Float = 16f,
) {
    val c = chatEnv.colors
    Box(
        modifier.heightIn(min = height).clip(RoundedCornerShape(radius)).border(1.dp, c.line, RoundedCornerShape(radius))
            .clickable(role = Role.Button, onClick = onClick).padding(horizontal = 18.dp),
        contentAlignment = Alignment.Center,
    ) {
        ChatText(text, size, FontWeight.Medium, c.ink, align = androidx.compose.ui.text.style.TextAlign.Center)
    }
}

/** A card with a hairline border and a soft shadow. */
internal fun Modifier.chatCard(c: ChatColors, radius: Dp = 16.dp): Modifier {
    val shape = RoundedCornerShape(radius)
    return this
        .shadow(if (c.dark) 8.dp else 6.dp, shape, clip = false, ambientColor = Color(0x14111426), spotColor = Color(0x30111426))
        .clip(shape)
        .background(c.card)
        .border(1.dp, c.line, shape)
}

/** A header background: gradient at 160 degrees (200 in right-to-left, as the web widget does), solid or light. */
internal fun Modifier.chatHeaderBackground(c: ChatColors, rtl: Boolean): Modifier =
    if (c.headerFrom == c.headerTo) background(c.headerFrom)
    else drawBehind {
        val angle = Math.toRadians((if (rtl) 200.0 else 160.0))
        val dx = sin(angle).toFloat()
        val dy = -cos(angle).toFloat()
        val half = (kotlin.math.abs(size.width * dx) + kotlin.math.abs(size.height * dy)) / 2f
        val center = Offset(size.width / 2f, size.height / 2f)
        drawRect(
            Brush.linearGradient(
                listOf(c.headerFrom, c.headerTo),
                start = center - Offset(dx * half, dy * half),
                end = center + Offset(dx * half, dy * half),
            ),
        )
    }
