package ai.zellio.chat.internal.ui

import ai.zellio.chat.R
import ai.zellio.chat.internal.core.OutboxAttachment
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.semantics.disabled
import kotlinx.coroutines.delay

internal sealed interface ComposerNotice {
    data class Error(val text: String) : ComposerNotice
    data object CameraDenied : ComposerNotice
}

/** The bottom bar: tray of chosen files, a notice line, and the pill with attach and send. */
@Composable
internal fun Composer(
    draftKey: String,
    allowAttach: Boolean,
    pending: List<OutboxAttachment>,
    notice: ComposerNotice?,
    onRemovePending: (OutboxAttachment) -> Unit,
    onAttach: () -> Unit,
    onOpenSettings: () -> Unit,
    onSend: (String) -> Unit,
) {
    val env = chatEnv
    val c = env.colors
    val s = env.strings
    val engine = env.engine
    var text by rememberSaveable(draftKey) { mutableStateOf(engine.draft(draftKey)) }
    // Drafts are saved by conversation, a moment after the last keystroke.
    LaunchedEffect(draftKey, text) {
        delay(400)
        engine.setDraft(draftKey, text)
    }
    val canSend = text.isNotBlank() || pending.isNotEmpty()
    val keyboard = LocalSoftwareKeyboardController.current
    val focus = LocalFocusManager.current

    Column(
        Modifier.fillMaxWidth().background(c.bg)
            .windowInsetsPadding(WindowInsets.navigationBars.union(WindowInsets.ime)),
    ) {
        Box(Modifier.fillMaxWidth().size(1.dp).background(c.line))
        when (notice) {
            is ComposerNotice.Error -> Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(Icons.alert, c.bad, 16.dp)
                ChatText(notice.text, 13f, color = c.bad, modifier = Modifier.weight(1f))
            }
            ComposerNotice.CameraDenied -> Row(
                Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 4.dp, bottom = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                ChatText(s[R.string.zc_composer_camera_denied], 13f, color = c.ink2, modifier = Modifier.weight(1f))
                Box(Modifier.heightIn(min = 48.dp).clickable(role = Role.Button, onClick = onOpenSettings).padding(horizontal = 8.dp), contentAlignment = Alignment.Center) {
                    ChatText(s[R.string.zc_composer_open_settings], 13.5f, FontWeight.SemiBold, c.link)
                }
            }
            null -> Unit
        }
        if (pending.isNotEmpty()) {
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                pending.forEach { Thumb(it) { onRemovePending(it) } }
            }
        }
        Row(
            Modifier.fillMaxWidth().padding(start = 4.dp, end = 10.dp, top = 6.dp, bottom = 8.dp),
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            if (allowAttach) {
                ChatIconButton(
                    s[R.string.zc_composer_attach], Icons.clip, c.ink2,
                    {
                        // The sheet slides up from the bottom: the keyboard must not cover it.
                        keyboard?.hide()
                        focus.clearFocus()
                        onAttach()
                    },
                    mirror = true,
                )
            } else {
                Box(Modifier.size(6.dp))
            }
            val pillShape = RoundedCornerShape(24.dp)
            Row(
                Modifier.weight(1f).heightIn(min = 48.dp).clip(pillShape).background(c.bgAlt).border(1.dp, c.line, pillShape)
                    .padding(start = 16.dp),
                verticalAlignment = Alignment.Bottom,
            ) {
                Box(Modifier.weight(1f).padding(vertical = 11.dp)) {
                    BasicTextField(
                        value = text,
                        onValueChange = { text = it.take(4000) },
                        modifier = Modifier.fillMaxWidth().semantics { if (text.isEmpty()) contentDescription = s[R.string.zc_composer_placeholder] },
                        textStyle = env.type.style(Roles.MESSAGE, FontWeight.Normal, c.ink).copy(textDirection = TextDirection.Content),
                        cursorBrush = SolidColor(c.primary),
                        minLines = 1,
                        maxLines = 6,
                        decorationBox = { inner ->
                            Box(Modifier.fillMaxWidth(), propagateMinConstraints = true) {
                                if (text.isEmpty()) ChatText(s[R.string.zc_composer_placeholder], Roles.MESSAGE, color = c.ink2, modifier = Modifier.fillMaxWidth())
                                inner()
                            }
                        },
                    )
                }
                // 36 dp circle inside a 48 dp touch area.
                Box(
                    Modifier.size(48.dp)
                        .semantics { contentDescription = s[R.string.zc_composer_send]; if (!canSend) disabled() }
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            enabled = canSend,
                            role = Role.Button,
                        ) {
                            onSend(text)
                            text = ""
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Box(
                        Modifier.size(36.dp).clip(CircleShape).background(if (canSend) c.primary else c.sendIdle),
                        contentAlignment = Alignment.Center,
                    ) { Icon(Icons.send, if (canSend) c.onPrimary else c.ink2, 20.dp, mirror = true) }
                }
            }
        }
    }
}

@Composable
private fun Thumb(att: OutboxAttachment, onRemove: () -> Unit) {
    val env = chatEnv
    val c = env.colors
    val bitmap by rememberBitmap(null, if (att.isImage) att.path else null, 240)
    Box(Modifier.size(64.dp)) {
        Box(Modifier.size(64.dp).clip(RoundedCornerShape(14.dp)).background(c.bgAlt), contentAlignment = Alignment.Center) {
            val bmp = bitmap
            if (bmp != null) BitmapImage(bmp, Modifier.fillMaxSize()) else Icon(Icons.file, c.ink2, 24.dp)
        }
        Box(
            Modifier.align(Alignment.TopEnd).size(48.dp)
                .semantics { contentDescription = env.strings[R.string.zc_attachment_cancel] }
                .clickable(role = Role.Button, onClick = onRemove),
            contentAlignment = Alignment.TopEnd,
        ) {
            Box(Modifier.padding(top = 2.dp, end = 2.dp).size(22.dp).clip(CircleShape).background(Color(0xCC090D28)), contentAlignment = Alignment.Center) {
                Icon(Icons.close, Color.White, 14.dp)
            }
        }
    }
}

/** "Camera, Photo library, File" and a cancel button, over a scrim. */
@Composable
internal fun AttachSheet(onCamera: () -> Unit, onPhotos: () -> Unit, onFiles: () -> Unit, onDismiss: () -> Unit) {
    val env = chatEnv
    val c = env.colors
    val s = env.strings
    Box(
        Modifier.fillMaxSize().background(c.scrim)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss),
    ) {
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().windowInsetsPadding(WindowInsets.navigationBars)
                .padding(start = 10.dp, end = 10.dp, bottom = 12.dp)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {},
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(c.card)) {
                SheetRow(Icons.camera, s[R.string.zc_composer_camera], onCamera)
                Box(Modifier.fillMaxWidth().size(1.dp).background(c.line))
                SheetRow(Icons.image, s[R.string.zc_composer_photos], onPhotos)
                Box(Modifier.fillMaxWidth().size(1.dp).background(c.line))
                SheetRow(Icons.file, s[R.string.zc_composer_files], onFiles)
            }
            Box(
                Modifier.fillMaxWidth().heightIn(min = 56.dp).clip(RoundedCornerShape(16.dp)).background(c.card)
                    .clickable(role = Role.Button, onClick = onDismiss),
                contentAlignment = Alignment.Center,
            ) { ChatText(s[R.string.zc_attachment_close], 17f, FontWeight.SemiBold) }
        }
    }
}

@Composable
private fun SheetRow(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    val c = chatEnv.colors
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(role = Role.Button, onClick = onClick).padding(horizontal = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Icon(icon, c.ink2, 22.dp)
        ChatText(label, 17f)
    }
}
