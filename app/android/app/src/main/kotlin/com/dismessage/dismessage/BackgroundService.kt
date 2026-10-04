package com.dismessage.dismessage

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * The one Flutter engine of the app. The screen ([MainActivity]) and the
 * background service both use it: the connection and the notifications
 * (Dart) keep running when the screen is closed, and opening the app shows
 * their current state.
 */
object EngineHolder {
    private var engine: FlutterEngine? = null
    var voice: VoiceHandler? = null
        private set
    var notifications: NotificationHandler? = null
        private set

    fun get(context: Context): FlutterEngine {
        engine?.let { return it }
        val app = context.applicationContext
        // Plugins are registered by the engine itself.
        val created = FlutterEngine(app)
        val messenger = created.dartExecutor.binaryMessenger
        val voiceChannel = MethodChannel(messenger, "dismessage/voice")
        voice = VoiceHandler(app, voiceChannel).also { voiceChannel.setMethodCallHandler(it) }
        val notifyChannel = MethodChannel(messenger, "dismessage/notify")
        notifications = NotificationHandler(app, notifyChannel)
            .also { notifyChannel.setMethodCallHandler(it) }
        val backgroundChannel = MethodChannel(messenger, "dismessage/background")
        backgroundChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    if (call.arguments == true) {
                        BackgroundService.start(app)
                    } else {
                        app.stopService(Intent(app, BackgroundService::class.java))
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        engine = created
        return created
    }

    /** Background mode chosen in the app (saved by Dart's SharedPreferences). */
    fun backgroundEnabled(context: Context): Boolean = context
        .getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        .getString("flutter.dismessage.background", null) == "true"
}

/**
 * Keeps Dismessage connected while its screen is closed, so messages,
 * typing and requests are still notified. Android requires a visible,
 * discreet notification for it.
 */
class BackgroundService : Service() {
    companion object {
        private const val CHANNEL_ID = "background"
        private const val NOTIFICATION_ID = 1

        fun start(context: Context) {
            val intent = Intent(context, BackgroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Starts the connection (Dart) if the screen has not done it yet.
        EngineHolder.get(this)
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Arrière-plan",
                NotificationManager.IMPORTANCE_MIN,
            )
            channel.description = "Indique que Dismessage reste joignable"
            channel.setShowBadge(false)
            manager.createNotificationChannel(channel)
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_MIN)
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return builder
            .setSmallIcon(R.mipmap.ic_launcher_monochrome)
            .setContentTitle("Dismessage est actif")
            .setContentText("Vous restez joignable, même appli fermée.")
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(open)
            .build()
    }
}

/** Starts the background mode when the phone starts, if it was chosen. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val started = intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == Intent.ACTION_MY_PACKAGE_REPLACED
        if (started && EngineHolder.backgroundEnabled(context)) {
            BackgroundService.start(context)
        }
    }
}
