package ai.zellio.chat

import ai.zellio.chat.internal.ui.ChatRoot
import ai.zellio.chat.internal.ui.StartRequest
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier

/**
 * Chat inside the host app's own navigation. Fills the space it is given. [onClose] runs when the customer taps
 * close or back on the first screen; the host decides what happens then. Nothing is shown (and one log line is
 * written) before [ZellioChat.configure].
 *
 * @param conversationId open this conversation; null starts where the layout says
 * @param newConversation with a null [conversationId]: open a new conversation
 */
@Composable
public fun ZellioChatScreen(
    modifier: Modifier = Modifier,
    conversationId: String? = null,
    newConversation: Boolean = false,
    onClose: () -> Unit = {},
) {
    val runtime = ZellioChat.runtimeOrNull()
    if (runtime == null) {
        ai.zellio.chat.internal.core.Log.w("ZellioChatScreen shown before configure")
        return
    }
    val start = remember(conversationId, newConversation) {
        StartRequest(conversationId, explicit = conversationId != null || newConversation)
    }
    ChatRoot(runtime, start, onClose, modifier, windowed = false)
}
