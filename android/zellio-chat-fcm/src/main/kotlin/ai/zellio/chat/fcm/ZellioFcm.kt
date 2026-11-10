package ai.zellio.chat.fcm

import ai.zellio.chat.R as ChatR
import ai.zellio.chat.ZellioChat
import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import com.google.firebase.messaging.RemoteMessage

/**
 * The forwarding helper. A brand that has its own `FirebaseMessagingService` calls these two functions from it;
 * [ZellioMessagingService] calls them for a brand that has none. Neither function throws.
 */
public object ZellioFcm {
    private const val CHANNEL_ID = "zellio_chat"

    /** Call from `FirebaseMessagingService.onNewToken`. */
    @JvmStatic
    public fun onNewToken(token: String) {
        ZellioChat.setPushToken(token)
    }

    /**
     * Call from `FirebaseMessagingService.onMessageReceived`. Returns true if the message was a ZeeChat push (so
     * the brand's own code can skip it). A data-only push that arrives while the app is closed or in the background
     * becomes a notification with no message text; the app's launcher activity opens on tap, and the brand passes
     * its intent to `ZellioChat.handleNotificationTap(intent)`.
     */
    @JvmStatic
    public fun onMessageReceived(context: Context, message: RemoteMessage): Boolean {
        return try {
            val data = message.data
            if (!ZellioChat.isZellioPush(data)) return false
            ZellioChat.handlePush(data)
            val inForeground = ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
            if (message.notification == null && !inForeground) show(context.applicationContext, data)
            true
        } catch (_: Throwable) {
            false
        }
    }

    private fun show(context: Context, data: Map<String, String>) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, context.getString(R.string.zcf_channel_name), NotificationManager.IMPORTANCE_HIGH),
            )
        }
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        data.forEach { (key, value) -> launch.putExtra(key, value) }
        val tap = PendingIntent.getActivity(context, 0, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val title = data["title"] ?: context.applicationInfo.loadLabel(context.packageManager).toString()
        val body = data["body"] ?: context.getString(ChatR.string.zc_push_new_message)
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(smallIcon(context))
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(tap)
            .setAutoCancel(true)
            .apply { notificationColor(context)?.let { setColor(it) } }
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .build()
        manager.notify(NOTIFICATION_ID, notification)
    }

    private const val NOTIFICATION_ID = 0x5A43
    private const val META_ICON = "ai.zellio.chat.notification_icon"
    private const val META_COLOR = "ai.zellio.chat.notification_color"
    private const val META_FIREBASE_ICON = "com.google.firebase.messaging.default_notification_icon"

    private fun meta(context: Context): android.os.Bundle? = try {
        context.packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA).metaData
    } catch (_: Throwable) {
        null
    }

    /**
     * The status bar needs a small single-colour icon. The brand sets `ai.zellio.chat.notification_icon` (a drawable
     * resource) in its manifest; Firebase's default icon is the second choice. The launcher icon is the last resort:
     * an adaptive icon can show as a white blob.
     */
    private fun smallIcon(context: Context): Int {
        val data = meta(context)
        val own = data?.getInt(META_ICON, 0) ?: 0
        if (own != 0) return own
        val firebase = data?.getInt(META_FIREBASE_ICON, 0) ?: 0
        return if (firebase != 0) firebase else context.applicationInfo.icon
    }

    /** Optional accent colour: `ai.zellio.chat.notification_color` (a colour resource). */
    private fun notificationColor(context: Context): Int? {
        val id = meta(context)?.getInt(META_COLOR, 0) ?: 0
        return if (id == 0) null else ContextCompat.getColor(context, id)
    }
}
