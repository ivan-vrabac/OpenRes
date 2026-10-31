package com.example.openres

import android.app.Activity
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * Game notifications without Firebase: the server keeps an inbox per player and [NotifyAlarm]
 * checks it every 15 minutes. (0.2.3: chat and its always-on "instant" connection are gone.)
 *
 * Channel "openres/chat": configure {base, sid}, logout, clear {tag}, takeOpen, deviceId.
 */
class ChatBridge(private val activity: Activity, messenger: BinaryMessenger) {

    init {
        MethodChannel(messenger, "openres/chat").setMethodCallHandler { call, result ->
            val ctx = activity.applicationContext
            when (call.method) {
                "configure" -> {
                    Poller.prefs(ctx).edit()
                        .putString("base", call.argument<String>("base"))
                        .putString("sid", call.argument<String>("sid"))
                        .apply()
                    Poller.start(ctx)
                    Poller.registerPush(ctx)
                    // the first check only notes where the inbox is: do it now, not after what comes next
                    Thread { try { Poller.pollOnce(ctx, 0) } catch (_: Exception) {} }.start()
                    result.success(true)
                }
                "logout" -> {
                    Poller.prefs(ctx).edit().remove("sid").remove("after").apply()
                    Poller.start(ctx)
                    Poller.dropPush()
                    result.success(true)
                }
                "clear" -> {
                    val tag = call.argument<String>("tag")
                    if (tag != null) {
                        NotificationManagerCompat.from(ctx).cancel(tag, 1)
                        Poller.lines.remove(tag)
                    }
                    result.success(true)
                }
                "takeOpen" -> { result.success(Poller.openTag); Poller.openTag = null }
                // multi-account detection (owner 2026-10-25): Android's ID for this app on this phone
                "deviceId" -> result.success(Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ANDROID_ID))
                else -> result.notImplemented()
            }
        }
        onIntent(activity.intent)
    }

    /** A tapped notification opened the app: Dart asks for the tag (takeOpen) and goes there. */
    fun onIntent(i: Intent?) {
        i?.getStringExtra(Poller.EXTRA_TAG)?.let { Poller.openTag = it; i.removeExtra(Poller.EXTRA_TAG) }
    }

}

/** Fetches the server's notification inbox and shows what is new. */
object Poller {
    const val EXTRA_TAG = "notif_tag"
    private const val CH_MESSAGES = "openres_messages"
    private const val CH_GAME = "openres_game"
    const val CH_CONNECTION = "openres_connection"

    /** The chat the player is looking at right now (no notification for it while the app is open). */
    @Volatile var viewing: String? = null
    @Volatile var foreground = false
    @Volatile var openTag: String? = null
    /** Recent lines per notification (a conversation shows its last few messages). */
    val lines = HashMap<String, ArrayList<String>>()

    fun prefs(ctx: Context) = ctx.getSharedPreferences("chat_notify", Context.MODE_PRIVATE)

    /** Hands this phone's push token to the server (no Firebase in this build: nothing happens). */
    fun registerPush(ctx: Context) {
        try {
            FirebaseMessaging.getInstance().token.addOnSuccessListener { token ->
                Thread { sendPushToken(ctx, token) }.start()
            }
        } catch (_: Exception) {}
    }

    /** Signed out: this phone stops being woken for that company. */
    fun dropPush() {
        try { FirebaseMessaging.getInstance().deleteToken() } catch (_: Exception) {}
    }

    fun sendPushToken(ctx: Context, token: String) {
        val p = prefs(ctx)
        val base = p.getString("base", null) ?: return
        val sid = p.getString("sid", null) ?: return
        try {
            val c = URL("$base/api/game/push/register").openConnection() as HttpURLConnection
            try {
                c.requestMethod = "POST"
                c.connectTimeout = 15_000
                c.readTimeout = 15_000
                c.doOutput = true
                c.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
                val body = "sid=${URLEncoder.encode(sid, "UTF-8")}&token=${URLEncoder.encode(token, "UTF-8")}"
                c.outputStream.use { it.write(body.toByteArray()) }
                c.responseCode
            } finally {
                c.disconnect()
            }
        } catch (_: Exception) {}
    }

    /** Start or stop the 15-minute check to match the sign-in. */
    fun start(ctx: Context) {
        val p = prefs(ctx)
        val on = p.getString("sid", null) != null && p.getString("base", null) != null
        // the 15-minute check: an inexact alarm (no WorkManager: its startup provider crashed the
        // release build, 1.1.2)
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val alarm = PendingIntent.getBroadcast(ctx, 4402, Intent(ctx, NotifyAlarm::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        if (on) {
            am.setInexactRepeating(AlarmManager.ELAPSED_REALTIME_WAKEUP,
                android.os.SystemClock.elapsedRealtime() + AlarmManager.INTERVAL_FIFTEEN_MINUTES,
                AlarmManager.INTERVAL_FIFTEEN_MINUTES, alarm)
        } else {
            am.cancel(alarm)
        }
    }

    fun channels(ctx: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.deleteNotificationChannel(CH_MESSAGES)                 // chat is gone (0.2.3)
        if (nm.getNotificationChannel(CH_GAME) == null) {
            nm.createNotificationChannel(NotificationChannel(CH_GAME, ctx.applicationInfo.loadLabel(ctx.packageManager),
                NotificationManager.IMPORTANCE_DEFAULT).apply { description = "Game alerts" })
        }
        nm.deleteNotificationChannel(CH_CONNECTION)               // so is the "Connected for messages" one
    }

    /**
     * One request; with [waitSec] the server holds it until a notification arrives.
     * Returns false when signed out (stop trying).
     */
    fun pollOnce(ctx: Context, waitSec: Int): Boolean {
        val p = prefs(ctx)
        val base = p.getString("base", null) ?: return false
        val sid = p.getString("sid", null) ?: return false
        val after = p.getLong("after", -1)
        val c = URL("$base/api/v1/notify/poll").openConnection() as HttpURLConnection
        try {
            c.requestMethod = "POST"
            c.connectTimeout = 15_000
            c.readTimeout = (waitSec + 20) * 1000
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
            val body = "sid=${URLEncoder.encode(sid, "UTF-8")}&after=$after&wait=$waitSec"
            c.outputStream.use { it.write(body.toByteArray()) }
            if (c.responseCode != 200) throw java.io.IOException("http ${c.responseCode}")
            val j = JSONObject(c.inputStream.bufferedReader().readText())
            if (j.optInt("err") != 0) {
                if (j.optString("code") == "auth") { p.edit().remove("sid").apply(); return false }
                return true
            }
            show(ctx, j)
            return true
        } finally {
            c.disconnect()
        }
    }

    @Synchronized
    private fun show(ctx: Context, j: JSONObject) {
        val p = prefs(ctx)
        val stored = p.getLong("after", -1)
        val items = j.optJSONArray("items")
        val next = j.optLong("next", stored)
        if (stored >= 0 && items != null) {
            channels(ctx)
            for (k in 0 until items.length()) {
                val it = items.getJSONObject(k)
                if (it.optLong("id") <= stored) continue
                val kind = it.optString("kind")
                val tag = it.optString("tag").ifEmpty { "n${it.optLong("id")}" }
                if (foreground && tag == viewing) continue
                post(ctx, tag, kind, it.optString("title"), it.optString("body"))
            }
        }
        if (next > stored) p.edit().putLong("after", next).apply()
    }

    private fun post(ctx: Context, tag: String, kind: String, title: String, body: String) {
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(ctx,
                android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) return
        val message = kind == "dm" || kind.startsWith("chat")
        val open = Intent(ctx, MainActivity::class.java).putExtra(EXTRA_TAG, tag)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pi = PendingIntent.getActivity(ctx, tag.hashCode(), open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val b = NotificationCompat.Builder(ctx, if (message) CH_MESSAGES else CH_GAME)
            .setSmallIcon(ctx.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setPriority(if (message) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(if (message) NotificationCompat.CATEGORY_MESSAGE else NotificationCompat.CATEGORY_EVENT)
        if (message) {
            // one notification per conversation, showing its last few messages
            val l = lines.getOrPut(tag) { ArrayList() }
            l.add(if (tag == "chat") "$title: $body" else body)
            while (l.size > 5) l.removeAt(0)
            val style = NotificationCompat.InboxStyle()
            l.forEach { style.addLine(it) }
            if (l.size > 1) b.setStyle(style).setNumber(l.size) else b.setStyle(NotificationCompat.BigTextStyle().bigText(body))
        } else {
            b.setStyle(NotificationCompat.BigTextStyle().bigText(body))
        }
        try { NotificationManagerCompat.from(ctx).notify(tag, 1, b.build()) } catch (_: SecurityException) {}
    }
}

/** Every 15 minutes (inexact alarm): fetch new game notifications. */
class NotifyAlarm : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val done = goAsync()
        Thread {
            try { Poller.pollOnce(ctx.applicationContext, 0) } catch (_: Exception) {}
            done.finish()
        }.start()
    }
}

/** After a reboot or an app update: schedule the 15-minute check again. */
class NotifyBootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        Poller.start(ctx)
    }
}
