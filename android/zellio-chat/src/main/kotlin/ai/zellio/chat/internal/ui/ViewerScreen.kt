package ai.zellio.chat.internal.ui

import ai.zellio.chat.R
import ai.zellio.chat.internal.engine.ViewerState
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlin.math.abs

/** Full-screen image: pinch to zoom, double tap to toggle, drag down to close. */
@Composable
internal fun ViewerScreen(state: ViewerState, onClose: () -> Unit) {
    val env = chatEnv
    var attempt by remember { mutableIntStateOf(0) }
    val image by rememberImage(state.url, state.localPath, 2048, attempt)
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    var drag by remember { mutableFloatStateOf(0f) }
    val shade = (1f - abs(drag) / 900f).coerceIn(0.25f, 1f)

    Box(
        Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.98f * shade))
            .pointerInput(Unit) {
                detectTapGestures(onTap = { if (image is ImageState.Failed) attempt++ }, onDoubleTap = {
                    scale = if (scale > 1.01f) 1f else 2.5f
                    offset = Offset.Zero
                })
            }
            .pointerInput(Unit) {
                val closeAt = 120.dp.toPx()
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    do {
                        val event = awaitPointerEvent()
                        val zoom = event.calculateZoom()
                        val pan = event.calculatePan()
                        if (event.changes.size > 1 || scale > 1.01f) {
                            scale = (scale * zoom).coerceIn(1f, 5f)
                            val limitX = size.width * (scale - 1f) / 2f
                            val limitY = size.height * (scale - 1f) / 2f
                            offset = Offset(
                                (offset.x + pan.x).coerceIn(-limitX, limitX),
                                (offset.y + pan.y).coerceIn(-limitY, limitY),
                            )
                            event.changes.forEach { it.consume() }
                        } else if (abs(pan.y) > abs(pan.x) || drag != 0f) {
                            drag += pan.y
                            event.changes.forEach { it.consume() }
                        }
                    } while (event.changes.any { it.pressed })
                    if (abs(drag) > closeAt) onClose() else drag = 0f
                    if (scale <= 1.01f) offset = Offset.Zero
                }
            },
    ) {
        val shown = image
        if (shown is ImageState.Failed) {
            Column(Modifier.align(Alignment.Center).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.image, Color.White.copy(alpha = 0.8f), 32.dp)
                ChatText(env.strings[R.string.zc_state_retry], 14f, FontWeight.Medium, Color.White.copy(alpha = 0.8f))
            }
        }
        if (shown is ImageState.Loaded) {
            BitmapImage(
                shown.bitmap,
                Modifier.fillMaxSize()
                    .semantics { contentDescription = state.name.ifBlank { env.strings[R.string.zc_attachment_photo] } }
                    .graphicsLayer {
                        scaleX = scale
                        scaleY = scale
                        translationX = offset.x
                        translationY = offset.y + drag
                    },
                ContentScale.Fit,
            )
        }
        ChatIconButton(
            env.strings[R.string.zc_attachment_close], Icons.close, Color.White, onClose,
            Modifier.align(Alignment.TopEnd).windowInsetsPadding(WindowInsets.statusBars).padding(8.dp),
            background = Color(0x66000000),
        )
    }
}
