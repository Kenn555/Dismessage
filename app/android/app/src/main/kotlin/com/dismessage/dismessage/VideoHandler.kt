package com.dismessage.dismessage

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * Decodes the peer's live video (channel "dismessage/video"): one H.264
 * MediaCodec decoder per view, on a thread of its own, drawing straight into
 * a Flutter texture (the image never goes through Dart). Platform APIs only:
 * no Gradle dependency. Dart sends one access unit at a time and waits for
 * the answer (the size of the image).
 */
class VideoHandler(private val textures: TextureRegistry) : MethodChannel.MethodCallHandler {

    companion object {
        const val MIME = "video/avc"

        /** Largest image shown (as Dart's kLiveMaxDecodedSide). */
        const val MAX_SIDE = 2560

        fun hasCodec(encoder: Boolean): Boolean = try {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
                info.isEncoder == encoder && info.supportedTypes.any { it.equals(MIME, ignoreCase = true) }
            }
        } catch (e: Exception) {
            false
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private val decoders = HashMap<Int, Decoder>()
    private var nextId = 1
    private val canDecode: Boolean by lazy { hasCodec(encoder = false) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "decoders" -> result.success(if (canDecode) listOf("h264") else emptyList())
            "create" -> {
                if (call.argument<String>("codec") != "h264" || !canDecode) {
                    result.error("unsupported", null, null)
                    return
                }
                val id = nextId++
                decoders[id] = Decoder(textures.createSurfaceProducer())
                result.success(id)
            }
            "decode" -> {
                val decoder = decoders[call.argument<Int>("id") ?: -1]
                val data = call.argument<ByteArray>("data")
                if (decoder == null || data == null) {
                    result.error("decoder", null, null)
                    return
                }
                decoder.decode(data, call.argument<Boolean>("key") == true, result)
            }
            "close" -> {
                decoders.remove(call.argument<Int>("id") ?: -1)?.release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** Everything stops (the engine goes). */
    fun releaseAll() {
        decoders.values.forEach { it.release() }
        decoders.clear()
    }

    private inner class Decoder(private val producer: TextureRegistry.SurfaceProducer) {
        private val thread = HandlerThread("dismessage-video").also { it.start() }
        private val handler = Handler(thread.looper)
        private var codec: MediaCodec? = null
        private var width = 0
        private var height = 0
        private var time = 0L

        /** The texture's surface was replaced: a new decoder, from a key frame. */
        @Volatile private var surfaceChanged = false
        @Volatile private var released = false

        init {
            producer.setSize(640, 480)
            producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() {
                    surfaceChanged = true
                }

                override fun onSurfaceCleanup() {
                    surfaceChanged = true
                }
            })
        }

        fun decode(data: ByteArray, key: Boolean, result: MethodChannel.Result) {
            handler.post {
                val answer: Any? = try {
                    decodeHere(data, key)
                } catch (e: Exception) {
                    closeCodec()
                    main.post { result.error("decoder", e.message, null) }
                    return@post
                }
                main.post { result.success(answer) }
            }
        }

        /** On the decoder's thread. */
        private fun decodeHere(data: ByteArray, key: Boolean): Any? {
            if (released) return null
            if (surfaceChanged) {
                surfaceChanged = false
                if (codec != null) {
                    closeCodec()
                    throw IllegalStateException("surface changed")
                }
            }
            val decoder = codec ?: run {
                // Only a key frame starts a stream.
                if (!key) throw IllegalStateException("no key frame")
                open()
            }
            val input = decoder.dequeueInputBuffer(100_000)
            if (input < 0) throw IllegalStateException("decoder stuck")
            val buffer = decoder.getInputBuffer(input) ?: throw IllegalStateException("no buffer")
            buffer.clear()
            buffer.put(data)
            decoder.queueInputBuffer(input, 0, data.size, time, 0)
            time += 33_333
            // Its image, drawn into the texture as soon as out; any older ones
            // first.
            val info = MediaCodec.BufferInfo()
            var rendered = false
            var wait = 40_000L
            while (true) {
                val output = decoder.dequeueOutputBuffer(info, wait)
                when {
                    output == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> readSize(decoder.outputFormat)
                    output >= 0 -> {
                        decoder.releaseOutputBuffer(output, true)
                        rendered = true
                        wait = 0
                    }
                    else -> break
                }
            }
            if (!rendered || width == 0 || height == 0) return null
            if (width > MAX_SIDE || height > MAX_SIDE) throw IllegalStateException("too large")
            return mapOf("w" to width, "h" to height, "texture" to producer.id())
        }

        private fun open(): MediaCodec {
            val format = MediaFormat.createVideoFormat(MIME, 640, 480)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // Each image out as soon as it is in.
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            val created = MediaCodec.createDecoderByType(MIME)
            try {
                created.configure(format, producer.surface, null, 0)
            } catch (e: Exception) {
                // An older decoder that does not know the low latency key.
                created.configure(MediaFormat.createVideoFormat(MIME, 640, 480), producer.surface, null, 0)
            }
            created.start()
            codec = created
            return created
        }

        private fun readSize(format: MediaFormat) {
            var w = format.getInteger(MediaFormat.KEY_WIDTH)
            var h = format.getInteger(MediaFormat.KEY_HEIGHT)
            // 1080 lines are coded as 1088: only the picture counts.
            if (format.containsKey("crop-right") && format.containsKey("crop-left")) {
                w = format.getInteger("crop-right") - format.getInteger("crop-left") + 1
            }
            if (format.containsKey("crop-bottom") && format.containsKey("crop-top")) {
                h = format.getInteger("crop-bottom") - format.getInteger("crop-top") + 1
            }
            width = w
            height = h
        }

        private fun closeCodec() {
            try {
                codec?.stop()
            } catch (e: Exception) {
                // Already in error.
            }
            try {
                codec?.release()
            } catch (e: Exception) {
                // Already released.
            }
            codec = null
        }

        fun release() {
            released = true
            handler.post {
                closeCodec()
                main.post { producer.release() }
                thread.quitSafely()
            }
        }
    }
}
