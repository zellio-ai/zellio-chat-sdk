package ai.zellio.chat.internal.ui

import ai.zellio.chat.internal.core.ChatLocale
import ai.zellio.chat.internal.core.Contrast
import ai.zellio.chat.internal.core.Palette
import ai.zellio.chat.internal.core.Shapes
import ai.zellio.chat.internal.engine.ChatEngine
import ai.zellio.chat.internal.platform.ImageLoader
import android.content.Context
import androidx.annotation.StringRes
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp

@Immutable
internal class ChatColors(p: Palette) {
    val dark = p.dark
    val bg = c(p.bg)
    val bgAlt = c(p.bgAlt)
    val ink = c(p.ink)
    val ink2 = c(p.ink2)
    val line = c(p.line)
    val agentBubble = c(p.agentBubble)
    val ok = c(p.ok)
    val bad = c(p.bad)
    val primary = c(p.primary)
    val onPrimary = c(p.onPrimary)
    val customer = c(p.customer)
    val onCustomer = c(p.onCustomer)
    val link = c(p.link)
    val headerFrom = c(p.headerFrom)
    val headerTo = c(p.headerTo)
    val onHeader = c(p.onHeader)
    val sendIdle = c(p.sendIdle)
    val warnBg = c(p.warnBg)
    val warnInk = c(p.warnInk)
    val card = if (p.dark) c(p.bgAlt) else c(p.bg)
    val scrim = Color(0x520D1228)

    private fun c(hex: String) = Color(Contrast.toArgb(hex))
}

/** Strings of the chat language, from the generated resources (independent of the device language). */
@Immutable
internal class Strings(private val ctx: Context) {
    operator fun get(@StringRes id: Int): String = ctx.getString(id)
}

@Immutable
internal class ChatType(val fontFamily: FontFamily?, val rtl: Boolean) {
    private val factor = if (rtl) 1.45f else 1.35f

    /** Line height is 1.45 x the size in Arabic and 1.35 x in English. No letter spacing on Arabic. */
    fun style(size: Float, weight: FontWeight, color: Color, content: Boolean = false): TextStyle = TextStyle(
        color = color,
        fontSize = size.sp,
        lineHeight = (size * factor).sp,
        fontWeight = weight,
        fontFamily = fontFamily,
        letterSpacing = 0.sp,
        textDirection = if (content) TextDirection.Content else TextDirection.Unspecified,
        platformStyle = PlatformTextStyle(includeFontPadding = false),
        lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None),
    )
}

internal class ChatEnv(
    val colors: ChatColors,
    val shapes: Shapes,
    val type: ChatType,
    val strings: Strings,
    val locale: ChatLocale,
    val reducedMotion: Boolean,
    val engine: ChatEngine,
    val images: ImageLoader,
    val brandName: String,
    val logoUrl: String?,
    val showAvatars: Boolean,
) {
    val rtl: Boolean get() = locale.rtl
    val layoutDirection: LayoutDirection get() = if (rtl) LayoutDirection.Rtl else LayoutDirection.Ltr
}

internal val LocalChat: ProvidableCompositionLocal<ChatEnv> = staticCompositionLocalOf { error("ZeeChat theme missing") }

internal val chatEnv: ChatEnv @Composable get() = LocalChat.current

/** Typography roles from SPEC.md. Sizes are sp, so they follow the Android font scale with no cap. */
internal object Roles {
    const val HOME_HEADING = 28f
    const val SCREEN_TITLE = 17f
    const val MESSAGE = 16f
    const val SECTION = 15f
    const val SECONDARY = 13f
    const val TIME = 12f
}

@Composable
internal fun ChatText(
    text: String,
    size: Float,
    weight: FontWeight = FontWeight.Normal,
    color: Color = chatEnv.colors.ink,
    modifier: Modifier = Modifier,
    maxLines: Int = Int.MAX_VALUE,
    align: TextAlign = TextAlign.Start,
    content: Boolean = false,
) {
    BasicText(
        text = text,
        modifier = modifier,
        style = chatEnv.type.style(size, weight, color, content).copy(textAlign = align),
        maxLines = maxLines,
        overflow = if (maxLines == Int.MAX_VALUE) TextOverflow.Clip else TextOverflow.Ellipsis,
    )
}

@Composable
internal fun ProvideChat(env: ChatEnv, content: @Composable () -> Unit) {
    CompositionLocalProvider(
        LocalChat provides env,
        androidx.compose.ui.platform.LocalLayoutDirection provides env.layoutDirection,
        content = content,
    )
}
