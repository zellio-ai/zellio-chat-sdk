package ai.zellio.chat

import ai.zellio.chat.internal.core.Guard
import ai.zellio.chat.internal.ui.ChatRoot
import ai.zellio.chat.internal.ui.StartRequest
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.key
import java.lang.ref.WeakReference

/** The window that [ZellioChat.present] opens. Declared in the library manifest; the host does not need to touch it. */
public class ZellioChatActivity : ComponentActivity() {
    private var request by mutableStateOf(StartRequest(null, false))
    private var serial by mutableStateOf(0L)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            enableEdgeToEdge()
            read(intent)
            val runtime = ZellioChat.runtimeOrNull()
            if (runtime == null) {
                finish()
                return
            }
            open.add(WeakReference(this))
            setContent {
                key(serial) {
                    ChatRoot(runtime, request, onClose = { finish() }, windowed = true)
                }
            }
        } catch (t: Throwable) {
            Guard.report("chat activity", t)
            finish()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Guard.run("new intent") { read(intent) }
    }

    override fun onDestroy() {
        open.removeAll { it.get() == null || it.get() === this }
        super.onDestroy()
    }

    private fun read(intent: Intent?) {
        request = StartRequest(
            conversationId = intent?.getStringExtra(EXTRA_CONVERSATION_ID),
            explicit = intent?.getBooleanExtra(EXTRA_EXPLICIT, false) ?: false,
        )
        serial = intent?.getLongExtra(EXTRA_SERIAL, 0L) ?: 0L
    }

    internal companion object {
        internal const val EXTRA_CONVERSATION_ID = "ai.zellio.chat.conversationId"
        internal const val EXTRA_EXPLICIT = "ai.zellio.chat.explicit"
        internal const val EXTRA_SERIAL = "ai.zellio.chat.serial"

        private val open = java.util.concurrent.CopyOnWriteArrayList<WeakReference<ZellioChatActivity>>()

        internal fun finishAll() {
            open.forEach { it.get()?.finish() }
        }
    }
}
