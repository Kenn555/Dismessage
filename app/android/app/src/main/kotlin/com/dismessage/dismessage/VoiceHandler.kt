package com.dismessage.dismessage

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Voice messages on Android with the platform APIs only (MediaRecorder,
 * MediaPlayer): no extra Gradle dependency. Channel "dismessage/voice".
 */
class VoiceHandler(
    private val activity: Activity,
    private val channel: MethodChannel,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val PERMISSION_REQUEST = 4207
    }

    private var recorder: MediaRecorder? = null
    private var recordPath: String? = null
    private var player: MediaPlayer? = null
    private var playFile: File? = null
    private var pendingPermission: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "hasPermission" -> hasPermission(call.argument<Boolean>("request") ?: true, result)
                "start" -> {
                    startRecording(call.argument<String>("path")!!, call.argument<Int>("bitRate")!!)
                    result.success(null)
                }
                "stop" -> result.success(stopRecording())
                "cancel" -> {
                    cancelRecording()
                    result.success(null)
                }
                "play" -> {
                    play(call.argument<ByteArray>("bytes")!!)
                    result.success(null)
                }
                "pause" -> {
                    player?.pause()
                    result.success(null)
                }
                "resume" -> {
                    player?.start()
                    result.success(null)
                }
                "stopPlayback" -> {
                    stopPlayback()
                    result.success(null)
                }
                "position" -> result.success(player?.currentPosition ?: 0)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("voice", e.message ?: e.javaClass.simpleName, null)
        }
    }

    private fun granted() = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
        activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
        PackageManager.PERMISSION_GRANTED

    private fun hasPermission(request: Boolean, result: MethodChannel.Result) {
        if (granted() || !request || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.success(granted())
            return
        }
        pendingPermission?.success(false)
        pendingPermission = result
        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST)
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_REQUEST) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermission?.success(granted)
        pendingPermission = null
    }

    private fun startRecording(path: String, bitRate: Int) {
        cancelRecording()
        val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(activity)
        } else {
            @Suppress("DEPRECATION")
            MediaRecorder()
        }
        try {
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioChannels(1)
            r.setAudioSamplingRate(16000)
            r.setAudioEncodingBitRate(bitRate)
            r.setOutputFile(path)
            r.prepare()
            r.start()
        } catch (e: Exception) {
            r.release()
            File(path).delete()
            throw e
        }
        recorder = r
        recordPath = path
    }

    /** Returns the file path, or null when nothing was captured. */
    private fun stopRecording(): String? {
        val r = recorder ?: return null
        val path = recordPath
        recorder = null
        recordPath = null
        return try {
            r.stop()
            path
        } catch (e: RuntimeException) {
            // Stopped too early: no valid file.
            path?.let { File(it).delete() }
            null
        } finally {
            r.release()
        }
    }

    private fun cancelRecording() {
        stopRecording()?.let { File(it).delete() }
    }

    private fun play(bytes: ByteArray) {
        stopPlayback()
        // MediaPlayer needs a file before API 23: keep it in the cache only
        // while playing.
        val file = File.createTempFile("dismessage_play", ".m4a", activity.cacheDir)
        file.writeBytes(bytes)
        val p = MediaPlayer()
        try {
            p.setDataSource(file.absolutePath)
            p.setOnCompletionListener {
                stopPlayback()
                channel.invokeMethod("onComplete", null)
            }
            p.prepare()
            p.start()
        } catch (e: Exception) {
            p.release()
            file.delete()
            throw e
        }
        player = p
        playFile = file
    }

    private fun stopPlayback() {
        player?.release()
        player = null
        playFile?.delete()
        playFile = null
    }

    fun release() {
        cancelRecording()
        stopPlayback()
    }
}
