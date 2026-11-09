package com.dismessage.dismessage

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Build
import java.io.ByteArrayOutputStream
import java.util.concurrent.LinkedBlockingQueue
import kotlin.math.max

/**
 * The sound of live views with the platform APIs only (no Gradle
 * dependency): AudioRecord reads the microphone with the echo canceller of
 * voice calls, AudioTrack plays the peer's sound. 16-bit mono PCM. Reached
 * through the "dismessage/voice" channel (VoiceHandler), which also asks for
 * the microphone permission.
 */
class LiveAudio(private val context: Context) {

    @Volatile private var recorder: AudioRecord? = null
    private var reader: Thread? = null
    private val captured = ByteArrayOutputStream()
    private val lock = Object()
    private var rate = 16000

    private val speakers = HashMap<Int, Speaker>()
    private var nextSpeaker = 1

    @SuppressLint("MissingPermission")
    fun openMic(rate: Int, device: String?) {
        closeMic()
        this.rate = rate
        val minimum = AudioRecord.getMinBufferSize(
            rate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minimum <= 0) throw IllegalStateException("format")
        // Half a second of room: Dart reads every packet or so.
        val r = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            rate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            max(minimum, rate),
        )
        if (r.state != AudioRecord.STATE_INITIALIZED) {
            r.release()
            throw IllegalStateException("busy")
        }
        if (device != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audio.getDevices(AudioManager.GET_DEVICES_INPUTS)
                .firstOrNull { it.id.toString() == device }
                ?.let { r.setPreferredDevice(it) }
        }
        r.startRecording()
        if (r.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            r.release()
            throw IllegalStateException("busy")
        }
        recorder = r
        val thread = Thread {
            // About one packet (40 ms) per read.
            val buffer = ByteArray(rate / 25 * 2)
            while (recorder === r) {
                val count = r.read(buffer, 0, buffer.size)
                if (count < 0) break
                if (count == 0) continue
                synchronized(lock) {
                    // Nobody reads anymore: no more than two seconds.
                    if (captured.size() < rate * 4) captured.write(buffer, 0, count)
                }
            }
        }
        thread.isDaemon = true
        thread.start()
        reader = thread
    }

    /** What was captured since the last read. */
    fun readMic(): ByteArray = synchronized(lock) {
        val out = captured.toByteArray()
        captured.reset()
        out
    }

    fun closeMic() {
        val r = recorder ?: return
        recorder = null
        try {
            r.stop()
        } catch (_: IllegalStateException) {
            // Not recording.
        }
        reader?.join(500)
        reader = null
        r.release()
        synchronized(lock) { captured.reset() }
    }

    fun openSpeaker(rate: Int): Int {
        val speaker = Speaker(rate)
        val id = nextSpeaker++
        speakers[id] = speaker
        return id
    }

    fun play(id: Int, pcm: ByteArray) {
        speakers[id]?.queue?.offer(pcm)
    }

    fun closeSpeaker(id: Int) {
        speakers.remove(id)?.close()
    }

    fun release() {
        closeMic()
        speakers.values.forEach { it.close() }
        speakers.clear()
    }

    /** One AudioTrack, fed by a thread of its own: writing may wait. */
    private class Speaker(rate: Int) {
        val queue = LinkedBlockingQueue<ByteArray>()
        @Volatile private var open = true
        private val track: AudioTrack
        private val writer: Thread

        init {
            val minimum = AudioTrack.getMinBufferSize(
                rate,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minimum <= 0) throw IllegalStateException("format")
            track = AudioTrack(
                AudioAttributes.Builder()
                    // The loudspeaker, not the earpiece of calls.
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
                AudioFormat.Builder()
                    .setSampleRate(rate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build(),
                // Half a second: the playout buffer (Dart) keeps less.
                max(minimum, rate),
                AudioTrack.MODE_STREAM,
                AudioManager.AUDIO_SESSION_ID_GENERATE,
            )
            if (track.state != AudioTrack.STATE_INITIALIZED) {
                track.release()
                throw IllegalStateException("no_output")
            }
            track.play()
            writer = Thread {
                try {
                    while (open) {
                        val pcm = queue.take()
                        if (!open) break
                        track.write(pcm, 0, pcm.size)
                    }
                } catch (_: InterruptedException) {
                    // Closed.
                }
            }
            writer.isDaemon = true
            writer.start()
        }

        fun close() {
            open = false
            writer.interrupt()
            writer.join(500)
            try {
                track.stop()
            } catch (_: IllegalStateException) {
                // Not playing.
            }
            track.release()
        }
    }
}
