package ai.zellio.chat.internal.engine

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

internal sealed interface Route {
    data object Home : Route
    data object ConversationList : Route

    /** [id] null is a new conversation. [resolveLatest] means: open the customer's current open conversation. */
    data class Thread(val id: String?, val resolveLatest: Boolean = false) : Route
}

internal data class ViewerState(val url: String?, val localPath: String?, val name: String)

internal object StartRoute {
    /** The screen `present()` starts on: the thread for `chat-only`, otherwise the home screen. */
    internal fun forLayout(layout: String?, conversationId: String?, explicitConversation: Boolean): Route = when {
        explicitConversation -> Route.Thread(conversationId)
        layout == "chat-only" -> Route.Thread(null, resolveLatest = true)
        else -> Route.Home
    }
}

/** Back stack of the chat. Plain class so the rules run on the JVM. */
internal class ChatNavigator(start: Route) {
    private val stackFlow = MutableStateFlow(listOf(start))
    private val viewerFlow = MutableStateFlow<ViewerState?>(null)

    internal val stack: StateFlow<List<Route>> get() = stackFlow
    internal val viewer: StateFlow<ViewerState?> get() = viewerFlow
    internal val top: Route get() = stackFlow.value.last()
    internal val canPop: Boolean get() = stackFlow.value.size > 1

    internal fun push(route: Route) {
        if (top == route) return
        stackFlow.value = stackFlow.value + route
    }

    internal fun replaceTop(route: Route) {
        stackFlow.value = stackFlow.value.dropLast(1) + route
    }

    /** Closes the viewer first, then pops. Returns false when the chat itself should close. */
    internal fun back(): Boolean {
        if (viewerFlow.value != null) {
            viewerFlow.value = null
            return true
        }
        if (!canPop) return false
        stackFlow.value = stackFlow.value.dropLast(1)
        return true
    }

    internal fun openViewer(state: ViewerState) {
        viewerFlow.value = state
    }

    internal fun closeViewer() {
        viewerFlow.value = null
    }
}
