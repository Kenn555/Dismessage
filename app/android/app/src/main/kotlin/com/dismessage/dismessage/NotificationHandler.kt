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
    private val context: Context,
    private val channel: MethodChannel,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val PERMISSION_REQUEST = 4208
        const val CHANNEL_ID = "messages"
        const val REPLY_KEY = "reply"
        const val EXTRA_TAG = "dismessage.tag"
        const val EXTRA_ACTION = "dismessage.action"
        const val ACTION_REPLY = "com.dismessage.dismessage.REPLY"
        const val ACTION_BUTTON = "com.dismessage.dismessage.BUTTON"

        /** The live handler, for [ReplyReceiver] (null once the app is gone). */
        var current: NotificationHandler? = null
    }

    private val manager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private var pendingPermission: MethodChannel.Result? = null

    /** The screen, when the app is shown: needed to ask for permissions. */
    var activity: Activity? = null

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
                        actions = call.argument<List<Map<String, Any?>>>("actions")
                            ?: emptyList(),
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
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(manager.areNotificationsEnabled())
            return
        }
        val screen = activity
        if (screen == null) {
            // Started in the background: asked again when the app is opened.
            result.success(false)
            return
        }
        pendingPermission?.success(false)
        pendingPermission = result
        screen.requestPermissions(
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

    private fun show(
        tag: String,
        title: String,
        lines: List<String>,
        alert: Boolean,
        reply: Boolean,
        actions: List<Map<String, Any?>>,
    ) {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context).setPriority(
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
        // Buttons (e.g. a request's « Accepter » / « Refuser »).
        for (button in actions) {
            val id = button["id"] as? String ?: continue
            val label = button["label"] as? String ?: id
            val intent = if (button["foreground"] == true) {
                actionActivityIntent(tag, id)
            } else {
                actionBroadcastIntent(tag, id)
            }
            builder.addAction(Notification.Action.Builder(null, label, intent).build())
        }
        manager.notify(tag, 0, builder.build())
    }

    /** A button that also opens the app (e.g. accepting a request). */
    private fun actionActivityIntent(tag: String, action: String): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            .putExtra(EXTRA_TAG, tag)
            .putExtra(EXTRA_ACTION, action)
        return PendingIntent.getActivity(
            context,
            "$tag/$action".hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** A button handled without showing the app (e.g. refusing). */
    private fun actionBroadcastIntent(tag: String, action: String): PendingIntent {
        val intent = Intent(context, ReplyReceiver::class.java)
            .setAction(ACTION_BUTTON)
            .putExtra(EXTRA_TAG, tag)
            .putExtra(EXTRA_ACTION, action)
        return PendingIntent.getBroadcast(
            context,
            "$tag/$action".hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun onAction(tag: String, action: String) {
        manager.cancel(tag, 0)
        channel.invokeMethod("onAction", mapOf("tag" to tag, "action" to action))
    }

    private fun openIntent(tag: String): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            .putExtra(EXTRA_TAG, tag)
        return PendingIntent.getActivity(
            context,
            tag.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun replyIntent(tag: String): PendingIntent {
        val intent = Intent(context, ReplyReceiver::class.java)
            .setAction(ACTION_REPLY)
            .putExtra(EXTRA_TAG, tag)
        // The reply text is added by the system: the intent must be mutable.
        val mutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE
        } else {
            0
        }
        return PendingIntent.getBroadcast(
            context,
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
        if (intent.action == NotificationHandler.ACTION_BUTTON) {
            val action = intent.getStringExtra(NotificationHandler.EXTRA_ACTION) ?: return
            val handler = NotificationHandler.current
            if (handler == null) {
                val manager =
                    context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.cancel(tag, 0)
            } else {
                handler.onAction(tag, action)
            }
            return
        }
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
