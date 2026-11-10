package ai.zellio.chat.sample

import ai.zellio.chat.ZellioChat
import ai.zellio.chat.ZellioChatScreen
import ai.zellio.chat.ZellioContext
import android.app.Application
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private val Teal = Color(0xFF0E7C86)
private val Ink = Color(0xFF14213D)
private val Muted = Color(0xFF5B6478)
private val Line = Color(0xFFE3E6EE)
private val Surface = Color(0xFFF6F7FA)

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { SampleHost(application) }
    }
}

private enum class Tab { SHOP, DEVELOPER, EMBEDDED }

@Composable
private fun SampleHost(app: Application) {
    var tab by remember { mutableStateOf(Tab.SHOP) }
    BackHandler(enabled = tab != Tab.SHOP) { tab = Tab.SHOP }
    Box(Modifier.fillMaxSize().background(Color.White)) {
        when (tab) {
            Tab.SHOP -> Shop(onHelp = { ZellioChat.present() }, onDeveloper = { tab = Tab.DEVELOPER })
            Tab.DEVELOPER -> Developer(app, onBack = { tab = Tab.SHOP }, onEmbedded = { tab = Tab.EMBEDDED })
            Tab.EMBEDDED -> ZellioChatScreen(Modifier.fillMaxSize(), onClose = { tab = Tab.DEVELOPER })
        }
    }
}

private data class Product(val name: String, val price: String, val color: Color)

private val products = listOf(
    Product("Cotton throw", "EGP 890", Color(0xFFF2D7B6)),
    Product("Brass lamp", "EGP 1,450", Color(0xFFE6C48A)),
    Product("Ceramic mug set", "EGP 420", Color(0xFFB7D3D6)),
    Product("Linen cushion", "EGP 380", Color(0xFFD9C6E8)),
)

@Composable
private fun Shop(onHelp: () -> Unit, onDeveloper: () -> Unit) {
    val unread by ZellioChat.unreadCount.collectAsState()
    LaunchedEffect(Unit) {
        ZellioChat.setContext(ZellioContext(screen = "Shop", itemType = "collection", itemId = "home", itemTitle = "Nile Store", url = "https://shop.example/"))
    }
    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).padding(horizontal = 20.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Nile Store", 24, FontWeight.Bold, Ink, Modifier.weight(1f))
            Box(
                Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).clickable(role = Role.Button, onClick = onDeveloper).padding(horizontal = 14.dp),
                contentAlignment = Alignment.Center,
            ) { Text("Developer", 14, FontWeight.Medium, Teal) }
        }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(Modifier.fillMaxWidth().heightIn(min = 150.dp).clip(RoundedCornerShape(20.dp)).background(Teal).padding(20.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Home for the season", 22, FontWeight.Bold, Color.White)
                    Text("Free delivery on orders over EGP 1,000.", 15, FontWeight.Normal, Color(0xFFD7F0F2))
                }
            }
            products.chunked(2).forEach { pair ->
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    pair.forEach { p ->
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Box(Modifier.fillMaxWidth().heightIn(min = 120.dp).clip(RoundedCornerShape(16.dp)).background(p.color))
                            Text(p.name, 15, FontWeight.SemiBold, Ink)
                            Text(p.price, 14, FontWeight.Normal, Muted)
                        }
                    }
                }
            }
            Box(Modifier.size(100.dp))
        }
    }
    Box(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.navigationBars).padding(20.dp), contentAlignment = Alignment.BottomEnd) {
        Box {
            Row(
                Modifier.heightIn(min = 56.dp).clip(RoundedCornerShape(28.dp)).background(Ink).clickable(role = Role.Button, onClick = onHelp).padding(horizontal = 22.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) { Text("Help", 16, FontWeight.SemiBold, Color.White) }
            if (unread > 0) {
                Box(
                    Modifier.align(Alignment.TopEnd).size(22.dp).background(Color(0xFFD9344B), CircleShape),
                    contentAlignment = Alignment.Center,
                ) { Text(unread.coerceAtMost(99).toString(), 12, FontWeight.Bold, Color.White) }
            }
        }
    }
}

@Composable
private fun Developer(app: Application, onBack: () -> Unit, onEmbedded: () -> Unit) {
    val settings = remember { Settings(app) }
    var offline by remember { mutableStateOf(settings.offline) }
    var baseUrl by remember { mutableStateOf(settings.baseUrl) }
    var appKey by remember { mutableStateOf(settings.appKey) }
    var token by remember { mutableStateOf(settings.token) }
    var locale by remember { mutableStateOf(settings.locale) }
    var theme by remember { mutableStateOf(settings.theme) }
    var down by remember { mutableStateOf(false) }
    val unread by ZellioChat.unreadCount.collectAsState()
    val context = LocalContext.current

    fun applyAll() {
        settings.offline = offline
        settings.baseUrl = baseUrl.trim()
        settings.appKey = appKey.trim()
        settings.token = token.trim()
        settings.locale = locale
        settings.theme = theme
        Demo.apply(app)
    }

    Column(
        Modifier.fillMaxSize().background(Surface).windowInsetsPadding(WindowInsets.statusBars)
            .verticalScroll(rememberScrollState()).windowInsetsPadding(WindowInsets.navigationBars).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Developer", 24, FontWeight.Bold, Ink, Modifier.weight(1f))
            Button("Back", filled = false, modifier = Modifier.padding(start = 12.dp), onClick = onBack)
        }
        Text("Unread: $unread", 15, FontWeight.Medium, Muted)

        Section("Server") {
            Row(
                Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(role = Role.Switch) { offline = !offline },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Offline demo (fake server in this app)", 15, FontWeight.Normal, Ink, Modifier.weight(1f))
                Box(Modifier.size(width = 46.dp, height = 28.dp).clip(RoundedCornerShape(14.dp)).background(if (offline) Teal else Line).padding(3.dp)) {
                    Box(Modifier.size(22.dp).align(if (offline) Alignment.CenterEnd else Alignment.CenterStart).background(Color.White, CircleShape))
                }
            }
            if (!offline) {
                Field("Base URL", baseUrl) { baseUrl = it }
                Field("App key", appKey) { appKey = it }
            }
            Field("Test identity token (JWT)", token) { token = it }
            Choice("Language", listOf("auto", "en", "ar"), locale) { locale = it }
            Choice("Theme", listOf("auto", "light", "dark"), theme) { theme = it }
            Button("Apply and configure") { applyAll() }
        }

        Section("Chat") {
            Button("present()") { ZellioChat.present() }
            Button("presentConversation(null): new conversation") { ZellioChat.presentConversation(null) }
            Button("Open chat inside this app (ZellioChatScreen)", filled = false, onClick = onEmbedded)
            Button("identify(tokenProvider)", filled = false) {
                settings.identified = true
                settings.token = token.trim()
                Demo.identify(app)
            }
            Button("logout()", filled = false) {
                settings.identified = false
                ZellioChat.logout()
            }
            Button("setContext(order 1042)", filled = false) {
                ZellioChat.setContext(ZellioContext("OrderDetails", "order", "1042", "Order 1042", "https://shop.example/orders/1042"))
            }
            Button("setContext(null)", filled = false) { ZellioChat.setContext(null) }
        }

        if (offline) {
            Section("Fake server") {
                Button("Agent writes a message", filled = false) { Demo.fake?.agentSays("Your order 1042 left the warehouse today.") }
                Button(if (down) "Bring the server back" else "Simulate no network", filled = false) {
                    down = !down
                    Demo.fake?.down = down
                }
            }
        }
        Text("SDK ${ai.zellio.chat.BuildConfig.SDK_VERSION} · ${context.packageName}", 12, FontWeight.Normal, Muted)
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color.White).border(1.dp, Line, RoundedCornerShape(16.dp)).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(title, 13, FontWeight.SemiBold, Muted)
        content()
    }
}

@Composable
private fun Field(label: String, value: String, onChange: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(label, 13, FontWeight.Normal, Muted)
        BasicTextField(
            value = value,
            onValueChange = onChange,
            singleLine = true,
            textStyle = TextStyle(color = Ink, fontSize = 15.sp),
            cursorBrush = SolidColor(Teal),
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(RoundedCornerShape(12.dp)).background(Surface).padding(horizontal = 12.dp, vertical = 14.dp),
        )
    }
}

@Composable
private fun Choice(label: String, options: List<String>, selected: String, onSelect: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(label, 13, FontWeight.Normal, Muted)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            options.forEach { o ->
                val on = o == selected
                Box(
                    Modifier.weight(1f).heightIn(min = 48.dp).clip(RoundedCornerShape(12.dp)).background(if (on) Teal else Surface)
                        .clickable(role = Role.RadioButton) { onSelect(o) },
                    contentAlignment = Alignment.Center,
                ) { Text(o, 14, FontWeight.Medium, if (on) Color.White else Ink) }
            }
        }
    }
}

@Composable
private fun Button(text: String, filled: Boolean = true, modifier: Modifier = Modifier.fillMaxWidth(), onClick: () -> Unit) {
    Box(
        modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(12.dp))
            .background(if (filled) Teal else Color.White).border(1.dp, if (filled) Teal else Line, RoundedCornerShape(12.dp))
            .clickable(role = Role.Button, onClick = onClick).padding(horizontal = 14.dp),
        contentAlignment = Alignment.Center,
    ) { Text(text, 15, FontWeight.SemiBold, if (filled) Color.White else Ink) }
}

@Composable
private fun Text(text: String, size: Int, weight: FontWeight, color: Color, modifier: Modifier = Modifier) {
    BasicText(text, modifier, TextStyle(color = color, fontSize = size.sp, fontWeight = weight, lineHeight = (size * 1.35f).sp))
}
