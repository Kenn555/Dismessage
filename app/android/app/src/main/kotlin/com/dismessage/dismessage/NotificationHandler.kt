package com.dismessage.dismessage

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Conversation notifications with an inline reply field, using the platform
 * APIs only (no extra Gradle dependency). Channel "dismessage/notify".
 */
class NotificationHandler(
    private val activity: Activity,
    private val channel: MethodChannel,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val PERMISSION_REQUEST = 4208
        const val CHANNEL_ID = "messages"
        const val REPLY_KEY = "reply"
        const val EXTRA_TAG = "dismessage.tag"
        const val ACTION_REPLY = "com.dismessage.dismessage.REPLY"

        /** The live handler, for [ReplyReceiver] (null once the app is gone). */
        var current: NotificationHandler? = null
    }

    private val manager =
        activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private var pendingPermission: MethodChannel.Result? = null

    init {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val messages = NotificationChannel(
                CHANNEL_ID,
                "Messages",
                NotificationManager.IMPORTANCE_HIGH,
            )
            messages.description = "Messages reçus et frappe en direct"
            manager.createNotificationChannel(messages)
        }
        current = this
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "requestPermission" -> requestPermission(result)
                "show" -> {
                    show(
                        tag = call.argument<String>("tag")!!,
                        title = call.argument<String>("title")!!,
                        lines = call.argument<List<String>>("lines") ?: emptyList(),
                        alert = call.argument<Boolean>("alert") ?: true,
                        reply = call.argument<Boolean>("reply") ?: false,
                    )
                    result.success(null)
                }
                "cancel" -> {
                    manager.cancel(call.argument<String>("tag"), 0)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("notify", e.message ?: e.javaClass.simpleName, null)
        }
    }

    private fun requestPermission(result: MethodChannel.Result) {
        // Before Android 13, notifications are allowed by default.
        if (Build.VERSION.SDK_INT < 33 ||
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(manager.areNotificationsEnabled())
            return
        }
        pendingPermission?.success(false)
        pendingPermission = result
        activity.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            PERMISSION_REQUEST,
        )
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_REQUEST) return
        pendingPermission?.success(
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED,
        )
        pendingPermission = null
    }

    private fun show(tag: String, title: String, lines: List<String>, alert: Boolean, reply: Boolean) {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(activity, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(activity).setPriority(
                if (alert) Notification.PRIORITY_HIGH else Notification.PRIORITY_LOW,
            )
        }
        val style = Notification.InboxStyle()
        lines.forEach { style.addLine(it) }
        builder
            .setSmallIcon(R.mipmap.ic_launcher_monochrome)
            .setContentTitle(title)
            .setContentText(lines.lastOrNull() ?: "")
            .setStyle(style)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            // Typing updates replace the notification without a new sound.
            .setOnlyAlertOnce(!alert)
            .setContentIntent(openIntent(tag))
        if (!alert && Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            builder.setDefaults(0)
        }
        // Inline reply field (shown from Android 7).
        if (reply && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val input = RemoteInput.Builder(REPLY_KEY).setLabel("Répondre…").build()
            val action = Notification.Action.Builder(null, "Répondre", replyIntent(tag))
                .addRemoteInput(input)
                .setAllowGeneratedReplies(false)
                .build()
            builder.addAction(action)
        }
        manager.notify(tag, 0, builder.build())
    }

    private fun openIntent(tag: String): PendingIntent {
        val intent = Intent(activity, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            .putExtra(EXTRA_TAG, tag)
        return PendingIntent.getActivity(
            activity,
            tag.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun replyIntent(tag: String): PendingIntent {
        val intent = Intent(activity, ReplyReceiver::class.java)
            .setAction(ACTION_REPLY)
            .putExtra(EXTRA_TAG, tag)
        // The reply text is added by the system: the intent must be mutable.
        val mutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE
        } else {
            0
        }
        return PendingIntent.getBroadcast(
            activity,
            tag.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or mutable,
        )
    }

    /** Notification tapped: tell Dart (it clears the notification). */
    fun onOpened(tag: String) {
        channel.invokeMethod("onOpen", mapOf("tag" to tag))
    }

    fun onReply(tag: String, text: String) {
        // Remove it: Android otherwise keeps a spinner in the reply field.
        manager.cancel(tag, 0)
        channel.invokeMethod("onReply", mapOf("tag" to tag, "text" to text))
    }

    fun release() {
        if (current === this) current = null
    }
}

/** Receives the text typed in a notification's reply field. */
class ReplyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val tag = intent.getStringExtra(NotificationHandler.EXTRA_TAG) ?: return
        val text = RemoteInput.getResultsFromIntent(intent)
            ?.getCharSequence(NotificationHandler.REPLY_KEY)
            ?.toString()
        val handler = NotificationHandler.current
        if (handler == null || text.isNullOrBlank()) {
            // The app was closed meanwhile: the conversation is over.
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.cancel(tag, 0)
            return
        }
        handler.onReply(tag, text)
    }
}
