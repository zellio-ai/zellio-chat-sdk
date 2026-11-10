package ai.zellio.chat.sample

import ai.zellio.chat.ZellioChat
import ai.zellio.chat.ZellioChatOptions
import ai.zellio.chat.ZellioLocale
import ai.zellio.chat.ZellioLogLevel
import ai.zellio.chat.ZellioTheme
import ai.zellio.chat.ZellioThemeMode
import android.app.Application
import android.content.Context

/** What the Developer tab edits. Plain SharedPreferences: this is a demo host app. */
class Settings(context: Context) {
    private val prefs = context.getSharedPreferences("sample", Context.MODE_PRIVATE)

    var offline: Boolean
        get() = prefs.getBoolean("offline", true)
        set(value) = prefs.edit().putBoolean("offline", value).apply()
    var baseUrl: String
        get() = prefs.getString("baseUrl", ZellioChatOptions.DEFAULT_BASE_URL).orEmpty()
        set(value) = prefs.edit().putString("baseUrl", value).apply()
    var appKey: String
        get() = prefs.getString("appKey", "").orEmpty()
        set(value) = prefs.edit().putString("appKey", value).apply()
    var token: String
        get() = prefs.getString("token", "").orEmpty()
        set(value) = prefs.edit().putString("token", value).apply()
    var locale: String
        get() = prefs.getString("locale", "auto").orEmpty()
        set(value) = prefs.edit().putString("locale", value).apply()
    var identified: Boolean
        get() = prefs.getBoolean("identified", false)
        set(value) = prefs.edit().putBoolean("identified", value).apply()
    var theme: String
        get() = prefs.getString("theme", "auto").orEmpty()
        set(value) = prefs.edit().putString("theme", value).apply()
}

object Demo {
    @Volatile
    var fake: FakeApi? = null
        private set

    fun identify(app: Application) {
        ZellioChat.identify {
            val s = Settings(app)
            s.token.ifBlank { if (s.offline) "demo.customer.token" else null }
        }
    }

    /** Configures the SDK from the saved settings. Safe to call again after the settings change. */
    fun apply(app: Application) {
        val s = Settings(app)
        val base: String
        val key: String
        if (s.offline) {
            val api = fake ?: FakeApi(app.assets).also { fake = it }
            base = "http://127.0.0.1:${api.start()}"
            key = "demo-app-key"
        } else {
            fake?.stop()
            fake = null
            base = s.baseUrl
            key = s.appKey
        }
        if (key.isBlank()) return
        ZellioChat.configure(
            app,
            key,
            ZellioChatOptions(
                baseUrl = base,
                locale = when (s.locale) {
                    "ar" -> ZellioLocale.ARABIC
                    "en" -> ZellioLocale.ENGLISH
                    else -> ZellioLocale.AUTO
                },
                theme = ZellioTheme(
                    mode = when (s.theme) {
                        "light" -> ZellioThemeMode.LIGHT
                        "dark" -> ZellioThemeMode.DARK
                        else -> ZellioThemeMode.AUTO
                    },
                ),
                logLevel = ZellioLogLevel.DEBUG,
            ),
        )
    }
}

class SampleApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Demo.apply(this)
        if (Settings(this).identified) Demo.identify(this)
    }
}
