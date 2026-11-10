package ai.zellio.chat.internal.ui

import ai.zellio.chat.R
import ai.zellio.chat.internal.core.Gate
import ai.zellio.chat.internal.engine.ChatNavigator
import ai.zellio.chat.internal.engine.Route
import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

/** The conversation list: a top bar with back and close, a large title, rows, and a floating "New conversation". */
@Composable
internal fun ConversationListScreen(navigator: ChatNavigator, onClose: () -> Unit) {
    val env = chatEnv
    val c = env.colors
    val s = env.strings
    val engine = env.engine
    val state by engine.conversations.collectAsState()
    val session by engine.session.collectAsState()
    val gateNow by engine.acceptedTerms.collectAsState()

    LaunchedEffect(gateNow, session != null) {
        if (engine.gate() == Gate.OPEN) {
            if (engine.ensureSession()) engine.loadConversations()
        }
    }

    Box(Modifier.fillMaxSize().background(c.bg)) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).padding(horizontal = 4.dp, vertical = 2.dp)) {
                if (navigator.canPop) ChatIconButton(s[R.string.zc_common_back], Icons.back, c.ink, { navigator.back() }, mirror = true)
                Box(Modifier.weight(1f))
                ChatIconButton(s[R.string.zc_common_close], Icons.close, c.ink2, onClose)
            }
            ChatText(
                s[R.string.zc_list_title], 30f, FontWeight.Bold,
                modifier = Modifier.padding(horizontal = 20.dp).padding(bottom = 10.dp).semantics { heading() },
            )
            Box(Modifier.fillMaxWidth().size(1.dp).background(c.line))
            when {
                state.items.isEmpty() && state.loading -> Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    ChatText(s[R.string.zc_state_loading], 15f, color = c.ink2)
                }
                state.items.isEmpty() && state.failed -> RetryState(s[R.string.zc_state_load_failed], Modifier.weight(1f)) { /* reloaded by effect */ engineReload(engine) }
                state.items.isEmpty() -> Column(
                    Modifier.weight(1f).fillMaxWidth().padding(horizontal = 32.dp),
                    verticalArrangement = Arrangement.spacedBy(18.dp, Alignment.CenterVertically),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    ChatText(s[R.string.zc_list_empty], 16f, color = c.ink2, align = TextAlign.Center)
                    NewConversationButton { navigator.push(Route.Thread(null)) }
                }
                else -> LazyColumn(Modifier.weight(1f).fillMaxWidth()) {
                    items(state.items, key = { it.id }) { item ->
                        ConversationRow(item, compact = false) { navigator.push(Route.Thread(item.id)) }
                        Box(Modifier.fillMaxWidth().size(1.dp).background(c.line))
                    }
                    item { Box(Modifier.size(100.dp)) }
                }
            }
        }
        if (state.items.isNotEmpty()) {
            Box(
                Modifier.align(Alignment.BottomCenter).windowInsetsPadding(WindowInsets.navigationBars).padding(bottom = 24.dp),
            ) {
                NewConversationButton { navigator.push(Route.Thread(null)) }
            }
        }
    }
}

private fun engineReload(engine: ai.zellio.chat.internal.engine.ChatEngine) {
    engine.scope.launch(ai.zellio.chat.internal.core.Guard.handler) { if (engine.ensureSession()) engine.loadConversations() }
}

@Composable
private fun NewConversationButton(onClick: () -> Unit) {
    val c = chatEnv.colors
    val shape = RoundedCornerShape(26.dp)
    FilledButton(
        chatEnv.strings[R.string.zc_list_new], onClick,
        Modifier.shadow(10.dp, shape, ambientColor = c.primary, spotColor = c.primary),
        height = 52.dp, radius = 26.dp, icon = Icons.plus,
    )
}

/** An error line with a "Try again" button. */
@Composable
internal fun RetryState(text: String, modifier: Modifier = Modifier, onRetry: () -> Unit) {
    val env = chatEnv
    Column(
        modifier.fillMaxWidth().padding(horizontal = 44.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        ChatText(text, 16f, FontWeight.Medium, align = TextAlign.Center)
        OutlinedButton(env.strings[R.string.zc_state_retry], onRetry, radius = 24.dp, size = 15.5f)
    }
}
