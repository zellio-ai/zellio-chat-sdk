package ai.zellio.chat.fcm

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * A ready `FirebaseMessagingService` for an app with no other push code. An app that has its own service removes
 * this one from the manifest and calls [ZellioFcm] from its own `onNewToken` and `onMessageReceived`.
 */
public open class ZellioMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        super.onNewToken(token)
        ZellioFcm.onNewToken(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)
        ZellioFcm.onMessageReceived(applicationContext, message)
    }
}
