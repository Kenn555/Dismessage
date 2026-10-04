package com.dismessage.dismessage

import android.content.Context
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    /** The shared engine: it outlives this screen (background mode). */
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        EngineHolder.get(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Channels and plugins are set up once, by EngineHolder; this screen
        // only lends itself for permission requests.
        EngineHolder.voice?.activity = this
        EngineHolder.notifications?.activity = this
        if (EngineHolder.backgroundEnabled(this)) BackgroundService.start(this)
    }

    /** A notification was tapped while the app was running. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val tag = intent.getStringExtra(NotificationHandler.EXTRA_TAG) ?: return
        val action = intent.getStringExtra(NotificationHandler.EXTRA_ACTION)
        if (action != null) {
            EngineHolder.notifications?.onAction(tag, action)
        } else {
            EngineHolder.notifications?.onOpened(tag)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        EngineHolder.voice?.onPermissionResult(requestCode, grantResults)
        EngineHolder.notifications?.onPermissionResult(requestCode, grantResults)
    }

    override fun onDestroy() {
        // The engine (connection, notifications) keeps running: only forget
        // this screen.
        if (EngineHolder.voice?.activity === this) EngineHolder.voice?.activity = null
        if (EngineHolder.notifications?.activity === this) {
            EngineHolder.notifications?.activity = null
        }
        super.onDestroy()
    }
}
