package com.example.openres

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Firebase Cloud Messaging: the server's push only says "something new", with no text in it. Google
 * wakes the app, and the same check as the 15-minute one fetches the notification from the inbox,
 * so settings and limits stay on the server and nothing is shown twice. No background service runs.
 */
class PushService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        try { Poller.pollOnce(applicationContext, 0) } catch (_: Exception) {}
    }

    override fun onNewToken(token: String) {
        Thread { Poller.sendPushToken(applicationContext, token) }.start()
    }
}
