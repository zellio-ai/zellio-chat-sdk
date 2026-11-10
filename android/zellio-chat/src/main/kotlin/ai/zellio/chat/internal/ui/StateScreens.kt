package ai.zellio.chat.internal.ui

import ai.zellio.chat.R
import ai.zellio.chat.internal.platform.AndroidEnv
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

/** "Chat is not available" (or login needed): an icon, one line, a close button. No technical words. */
@Composable
internal fun UnavailableScreen(text: String, icon: androidx.compose.ui.graphics.vector.ImageVector, onClose: () -> Unit, onRetry: (() -> Unit)? = null) {
    val env = chatEnv
    val c = env.colors
    Column(Modifier.fillMaxSize().background(c.bg)) {
        Row(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).padding(horizontal = 4.dp, vertical = 2.dp)) {
            Box(Modifier.weight(1f))
            ChatIconButton(env.strings[R.string.zc_common_close], Icons.close, c.ink2, onClose)
        }
        Column(
            Modifier.weight(1f).fillMaxWidth().padding(horizontal = 44.dp).padding(bottom = 96.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(Modifier.size(64.dp).clip(RoundedCornerShape(20.dp)).background(c.bgAlt), contentAlignment = Alignment.Center) {
                Icon(icon, c.ink2, 30.dp)
            }
            ChatText(text, 17f, FontWeight.Medium, align = TextAlign.Center, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
            if (onRetry != null) FilledButton(env.strings[R.string.zc_state_retry], onRetry, radius = 24.dp, height = 48.dp)
            OutlinedButton(env.strings[R.string.zc_attachment_close], onClose, radius = 24.dp, size = 15.5f)
        }
    }
}

/** A calm skeleton while the first config or page loads. */
@Composable
internal fun SkeletonScreen(onClose: () -> Unit) {
    val env = chatEnv
    val c = env.colors
    val label = env.strings[R.string.zc_state_loading]
    val transition = rememberInfiniteTransition(label = "skeleton")
    val pulse by transition.animateFloat(
        initialValue = 0.55f, targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(900), RepeatMode.Reverse), label = "pulse",
    )
    val alpha = if (env.reducedMotion) 0.8f else pulse
    Column(Modifier.fillMaxSize().background(c.bg).semantics { contentDescription = label }) {
        Row(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).padding(horizontal = 4.dp, vertical = 2.dp)) {
            Box(Modifier.weight(1f))
            ChatIconButton(env.strings[R.string.zc_common_close], Icons.close, c.ink2, onClose)
        }
        Column(Modifier.padding(20.dp).alpha(alpha), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.fillMaxWidth(0.55f).size(height = 28.dp, width = 160.dp).clip(RoundedCornerShape(10.dp)).background(c.bgAlt))
            Box(Modifier.fillMaxWidth().size(height = 84.dp, width = 300.dp).clip(RoundedCornerShape(16.dp)).background(c.bgAlt))
            Box(Modifier.fillMaxWidth().size(height = 84.dp, width = 300.dp).clip(RoundedCornerShape(16.dp)).background(c.bgAlt))
        }
    }
}

/** Placeholder bubbles while a thread loads (same height as real ones, so nothing jumps). */
@Composable
internal fun ThreadSkeleton(modifier: Modifier = Modifier) {
    val env = chatEnv
    val c = env.colors
    val transition = rememberInfiniteTransition(label = "thread-skeleton")
    val pulse by transition.animateFloat(
        initialValue = 0.55f, targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(900), RepeatMode.Reverse), label = "pulse",
    )
    val alpha = if (env.reducedMotion) 0.8f else pulse
    Column(
        modifier.fillMaxSize().padding(14.dp).alpha(alpha).semantics { contentDescription = env.strings[R.string.zc_state_loading] },
        verticalArrangement = Arrangement.spacedBy(10.dp, Alignment.Bottom),
    ) {
        Box(Modifier.align(Alignment.End).size(width = 200.dp, height = 40.dp).clip(RoundedCornerShape(20.dp)).background(c.bgAlt))
        Box(Modifier.size(width = 260.dp, height = 64.dp).clip(RoundedCornerShape(20.dp)).background(c.bgAlt))
        Box(Modifier.align(Alignment.End).size(width = 160.dp, height = 40.dp).clip(RoundedCornerShape(20.dp)).background(c.bgAlt))
    }
}

/** The consent card: shown before the first session. Accept is saved per install and version. */
@Composable
internal fun ConsentSheet(text: String, privacyUrl: String?, onAccept: () -> Unit, onDecline: () -> Unit) {
    val env = chatEnv
    val c = env.colors
    val s = env.strings
    val context = LocalContext.current
    Box(
        Modifier.fillMaxSize().background(c.scrim)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDecline),
    ) {
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                .shadow(20.dp, RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp), ambientColor = Color(0x59090D28), spotColor = Color(0x59090D28))
                .clip(RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp))
                .background(c.bg)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
                .windowInsetsPadding(WindowInsets.navigationBars)
                .padding(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 20.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Box(Modifier.align(Alignment.CenterHorizontally).size(width = 38.dp, height = 5.dp).clip(RoundedCornerShape(3.dp)).background(c.line))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Logo(44.dp, 13.dp, onHeader = false)
                ChatText(env.brandName, 19f, FontWeight.Bold, modifier = Modifier.weight(1f))
            }
            ChatText(text, 16f, color = c.ink, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
            if (!privacyUrl.isNullOrBlank()) {
                ChatText(
                    s[R.string.zc_consent_privacy], 14.5f, FontWeight.Medium, c.link,
                    Modifier.clickable(role = Role.Button) { AndroidEnv.openLink(context, privacyUrl) }.padding(vertical = 14.dp)
                        .semantics { contentDescription = s[R.string.zc_consent_privacy] },
                )
            }
            FilledButton(s[R.string.zc_consent_accept], onAccept, Modifier.fillMaxWidth())
            OutlinedButton(s[R.string.zc_consent_decline], onDecline, Modifier.fillMaxWidth(), height = 48.dp)
        }
    }
}

