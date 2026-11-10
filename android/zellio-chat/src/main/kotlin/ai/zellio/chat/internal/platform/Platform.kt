package ai.zellio.chat.internal.platform

import ai.zellio.chat.internal.core.ChatLocale
import ai.zellio.chat.internal.core.Guard
import ai.zellio.chat.internal.core.KeyValueStore
import ai.zellio.chat.internal.core.Log
import ai.zellio.chat.internal.core.SecretVault
import android.content.Context
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.Network
import android.provider.Settings
import android.util.Base64
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.core.content.FileProvider
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** The camera needs a FileProvider to hand the system camera a place to write. */
internal class ZellioFileProvider : FileProvider()

/**
 * The session record, encrypted with an AES-256-GCM key that lives in the Android Keystore. The key never leaves
 * the secure hardware or the Keystore process. If the Keystore cannot be used on this device, the record is kept
 * in memory only and the customer simply gets a new session next launch: it is never written in clear text.
 */
internal class KeystoreVault(private val store: KeyValueStore) : SecretVault {
    @Volatile
    private var memoryOnly: String? = null

    @Volatile
    private var keystoreBroken = false

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance("AES", PROVIDER)
        generator.init(
            android.security.keystore.KeyGenParameterSpec.Builder(
                ALIAS,
                android.security.keystore.KeyProperties.PURPOSE_ENCRYPT or android.security.keystore.KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(android.security.keystore.KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(android.security.keystore.KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    @Synchronized
    override fun load(): String? {
        memoryOnly?.let { return it }
        if (keystoreBroken) return null
        return try {
            val raw = store.read(FILE) ?: return null
            val bytes = Base64.decode(raw, Base64.NO_WRAP)
            val iv = bytes.copyOfRange(0, IV_BYTES)
            val cipher = Cipher.getInstance(TRANSFORM)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
            String(cipher.doFinal(bytes, IV_BYTES, bytes.size - IV_BYTES), Charsets.UTF_8)
        } catch (t: Throwable) {
            // A lost or changed key (restore, lock screen reset) means the record cannot be read: start clean.
            Log.w("session record unreadable", t)
            store.delete(FILE)
            null
        }
    }

    @Synchronized
    override fun save(value: String) {
        if (keystoreBroken) {
            memoryOnly = value
            return
        }
        try {
            val cipher = Cipher.getInstance(TRANSFORM)
            cipher.init(Cipher.ENCRYPT_MODE, key())
            val iv = cipher.iv
            val out = iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
            store.write(FILE, Base64.encodeToString(out, Base64.NO_WRAP))
            memoryOnly = null
        } catch (t: Throwable) {
            Guard.report("keystore", t)
            keystoreBroken = true
            memoryOnly = value
        }
    }

    @Synchronized
    override fun clear() {
        memoryOnly = null
        store.delete(FILE)
    }

    private companion object {
        const val PROVIDER = "AndroidKeyStore"
        const val ALIAS = "ai.zellio.chat.session.v1"
        const val FILE = "session.enc"
        const val TRANSFORM = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
    }
}

internal object AndroidEnv {
    /** A Context whose resources follow the chat language, whatever the device language is. */
    internal fun localizedContext(base: Context, locale: ChatLocale): Context {
        val cfg = Configuration(base.resources.configuration)
        val java = java.util.Locale.forLanguageTag(locale.tag)
        cfg.setLocale(java)
        cfg.setLayoutDirection(java)
        return base.createConfigurationContext(cfg)
    }

    /** True when the system animation scale is 0 (Remove animations / reduced motion). */
    internal fun reducedMotion(context: Context): Boolean = try {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    } catch (_: Throwable) {
        false
    }

    internal fun haptic(view: View, kind: ai.zellio.chat.internal.engine.HapticKind) {
        Guard.run("haptic") {
            // performHapticFeedback follows the system "touch feedback" setting unless told otherwise.
            val constant = when (kind) {
                ai.zellio.chat.internal.engine.HapticKind.SEND -> HapticFeedbackConstants.KEYBOARD_TAP
                ai.zellio.chat.internal.engine.HapticKind.RECEIVE -> HapticFeedbackConstants.CLOCK_TICK
                ai.zellio.chat.internal.engine.HapticKind.FAILED ->
                    if (android.os.Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.REJECT else HapticFeedbackConstants.LONG_PRESS
            }
            view.performHapticFeedback(constant)
        }
    }

    /** A short notification sound, only if the phone is not silent or on vibrate. */
    internal fun playSound(context: Context) {
        Guard.run("sound") {
            val audio = context.getSystemService(Context.AUDIO_SERVICE) as? android.media.AudioManager ?: return
            if (audio.ringerMode != android.media.AudioManager.RINGER_MODE_NORMAL) return
            val uri = android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_NOTIFICATION)
            android.media.RingtoneManager.getRingtone(context, uri)?.play()
        }
    }

    internal fun openLink(context: Context, url: String) {
        Guard.run("open link") {
            val lower = url.lowercase()
            val uri = android.net.Uri.parse(url)
            val intent = when {
                lower.startsWith("https://") -> android.content.Intent(android.content.Intent.ACTION_VIEW, uri)
                lower.startsWith("mailto:") -> android.content.Intent(android.content.Intent.ACTION_SENDTO, uri)
                lower.startsWith("tel:") -> android.content.Intent(android.content.Intent.ACTION_DIAL, uri)
                else -> return // anything else is never opened
            }
            intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        }
    }
}

/**
 * Best-effort network hint. It needs ACCESS_NETWORK_STATE, which the SDK does not declare; if the host app has it
 * this wakes the queue a little sooner, if not the timers do the same job.
 */
internal class NetworkHint(private val context: Context, private val onAvailable: () -> Unit) {
    private var callback: ConnectivityManager.NetworkCallback? = null

    internal fun start() {
        try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    Guard.run("network hint") { onAvailable() }
                }
            }
            cm.registerDefaultNetworkCallback(cb)
            callback = cb
        } catch (_: Throwable) {
            // no permission: fine
        }
    }

    internal fun stop() {
        try {
            val cb = callback ?: return
            (context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager)?.unregisterNetworkCallback(cb)
        } catch (_: Throwable) {
        }
        callback = null
    }
}
