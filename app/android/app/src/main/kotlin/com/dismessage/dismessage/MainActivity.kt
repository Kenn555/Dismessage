package com.dismessage.dismessage

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var voice: VoiceHandler? = null
    private var notifications: NotificationHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val voiceChannel = MethodChannel(messenger, "dismessage/voice")
        voice = VoiceHandler(this, voiceChannel).also { voiceChannel.setMethodCallHandler(it) }
        val notifyChannel = MethodChannel(messenger, "dismessage/notify")
        notifications = NotificationHandler(this, notifyChannel)
            .also { notifyChannel.setMethodCallHandler(it) }
    }

    /** A notification was tapped while the app was running. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra(NotificationHandler.EXTRA_TAG)?.let {
            notifications?.onOpened(it)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        voice?.onPermissionResult(requestCode, grantResults)
        notifications?.onPermissionResult(requestCode, grantResults)
    }

    override fun onDestroy() {
        voice?.release()
        notifications?.release()
        super.onDestroy()
    }
}
