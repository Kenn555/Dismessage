package com.dismessage.dismessage

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.Image
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Range
import android.util.Size
import android.view.Surface
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * The camera as a source of small JPEG frames for the live view, with the
 * platform APIs only (Camera2): no extra Gradle dependency. Channel
 * "dismessage/camera". Only a frame that was asked for is encoded, the
 * freshest one. Android cuts the camera of an app in the background.
 */
class LiveCameraHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val PERMISSION_REQUEST = 4211
    }

    /** The screen, when the app is shown: needed to ask for the permission. */
    var activity: Activity? = null

    private val main = Handler(Looper.getMainLooper())
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null
    private var sensorRotation = 0
    private var front = false
    private var side = 320
    private var sizes: Array<Size>? = null
    private var chosen: String? = null
    private var fpsRange: Range<Int>? = null
    private var opening: MethodChannel.Result? = null
    private var waitingPermission: MethodChannel.Result? = null

    /** The frame asked for; only touched on the camera's thread once set. */
    @Volatile private var wanted: Wanted? = null

    private class Wanted(val quality: Int, val result: MethodChannel.Result)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "open" -> {
                side = call.argument<Int>("side") ?: 320
                chosen = call.argument<String>("device")
                open(result)
            }
            "list" -> result.success(list())
            "capture" -> {
                side = call.argument<Int>("side") ?: 320
                recapture()
                result.success(null)
            }
            "frame" -> {
                if (device == null) {
                    result.error("stopped", null, null)
                } else {
                    // Only the latest request counts.
                    wanted?.result?.success(null)
                    wanted = Wanted(call.argument<Int>("quality") ?: 50, result)
                }
            }
            "close" -> {
                close()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** The cameras, named by the side they face (no permission needed). */
    private fun list(): List<Map<String, String>> {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        return try {
            var front = 0
            var back = 0
            manager.cameraIdList.map { id ->
                val facing = manager.getCameraCharacteristics(id)
                    .get(CameraCharacteristics.LENS_FACING)
                val label = when (facing) {
                    CameraCharacteristics.LENS_FACING_FRONT ->
                        if (front++ == 0) "Caméra avant" else "Caméra avant $front"
                    CameraCharacteristics.LENS_FACING_BACK ->
                        if (back++ == 0) "Caméra arrière" else "Caméra arrière $back"
                    else -> "Caméra externe $id"
                }
                mapOf("id" to id, "label" to label)
            }
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun granted() = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
        context.checkSelfPermission(Manifest.permission.CAMERA) ==
        PackageManager.PERMISSION_GRANTED

    private fun open(result: MethodChannel.Result) {
        close()
        if (granted()) {
            start(result)
            return
        }
        val screen = activity
        if (screen == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.error("denied", null, null)
            return
        }
        waitingPermission?.error("denied", null, null)
        waitingPermission = result
        screen.requestPermissions(arrayOf(Manifest.permission.CAMERA), PERMISSION_REQUEST)
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_REQUEST) return
        val result = waitingPermission ?: return
        waitingPermission = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            start(result)
        } else {
            result.error("denied", null, null)
        }
    }

    @SuppressLint("MissingPermission") // Checked by open().
    private fun start(result: MethodChannel.Result) {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        try {
            val ids = manager.cameraIdList
            // The one chosen in the settings if still there, else the front
            // camera: it is the one that shows the person.
            val id = ids.firstOrNull { it == chosen } ?: ids.firstOrNull {
                manager.getCameraCharacteristics(it)
                    .get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT
            } ?: ids.firstOrNull()
            if (id == null) {
                result.error("no_camera", null, null)
                return
            }
            val info = manager.getCameraCharacteristics(id)
            front = info.get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_FRONT
            sensorRotation = info.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
            fpsRange = info.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                ?.filter { it.upper >= 30 }
                ?.maxByOrNull { it.lower }
            val map = info.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            sizes = map?.getOutputSizes(ImageFormat.YUV_420_888)
            val size = chooseSize(sizes)
            if (size == null) {
                result.error("unavailable", null, null)
                return
            }
            val worker = HandlerThread("dismessage-camera").also { it.start() }
            thread = worker
            val background = Handler(worker.looper)
            handler = background
            val images = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 2)
            images.setOnImageAvailableListener({ onImage(it) }, background)
            reader = images
            opening = result
            manager.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    device = camera
                    startSession(camera, images, background)
                }

                override fun onDisconnected(camera: CameraDevice) {
                    camera.close()
                    fail("stopped")
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    camera.close()
                    fail(
                        if (error == CameraDevice.StateCallback.ERROR_CAMERA_IN_USE ||
                            error == CameraDevice.StateCallback.ERROR_MAX_CAMERAS_IN_USE
                        ) "busy" else "stopped",
                    )
                }
            }, background)
        } catch (e: Exception) {
            close()
            result.error("unavailable", e.message, null)
        }
    }

    /** Full screen asks for more, leaving it for less: a new session. */
    private fun recapture() {
        val camera = device ?: return
        val background = handler ?: return
        val size = chooseSize(sizes) ?: return
        val old = reader
        if (old != null && old.width == size.width && old.height == size.height) return
        try {
            session?.close()
        } catch (e: Exception) {
            // Already closed.
        }
        session = null
        val images = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 2)
        images.setOnImageAvailableListener({ onImage(it) }, background)
        reader = images
        old?.close()
        startSession(camera, images, background)
    }

    /** The smallest size at least [side] pixels long. */
    private fun chooseSize(sizes: Array<Size>?): Size? {
        if (sizes.isNullOrEmpty()) return null
        return sizes.filter { maxOf(it.width, it.height) >= side }
            .minByOrNull { it.width * it.height }
            ?: sizes.maxByOrNull { it.width * it.height }
    }

    @Suppress("DEPRECATION") // The newer call needs API 28; this one exists everywhere.
    private fun startSession(camera: CameraDevice, images: ImageReader, background: Handler) {
        try {
            camera.createCaptureSession(
                listOf(images.surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(capture: CameraCaptureSession) {
                        session = capture
                        try {
                            val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                            request.addTarget(images.surface)
                            // 30 images per second, as steadily as this camera
                            // allows, even in dim light.
                            fpsRange?.let {
                                request.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it)
                            }
                            capture.setRepeatingRequest(request.build(), null, background)
                            main.post {
                                opening?.success(null)
                                opening = null
                            }
                        } catch (e: Exception) {
                            fail("unavailable")
                        }
                    }

                    override fun onConfigureFailed(capture: CameraCaptureSession) {
                        fail("unavailable")
                    }
                },
                background,
            )
        } catch (e: Exception) {
            fail("unavailable")
        }
    }

    private fun fail(code: String) {
        main.post {
            opening?.error(code, null, null)
            opening = null
            wanted?.result?.error(code, null, null)
            wanted = null
            close()
        }
    }

    /** On the camera's thread: encodes the newest image if one is wanted. */
    private fun onImage(images: ImageReader) {
        val image = images.acquireLatestImage() ?: return
        image.use {
            val request = wanted ?: return
            wanted = null
            val jpeg = try {
                encode(it, request.quality)
            } catch (e: Exception) {
                null
            }
            main.post { request.result.success(jpeg) }
        }
    }

    private fun rotation(): Int {
        @Suppress("DEPRECATION")
        val display = activity?.windowManager?.defaultDisplay?.rotation ?: Surface.ROTATION_0
        val degrees = when (display) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
        return if (front) (sensorRotation + degrees) % 360 else (sensorRotation - degrees + 360) % 360
    }

    private fun encode(image: Image, quality: Int): ByteArray {
        val width = image.width
        val height = image.height
        val nv21 = toNv21(image)
        val turns = rotation()
        val rotated = rotateNv21(nv21, width, height, turns)
        val outWidth = if (turns % 180 == 0) width else height
        val outHeight = if (turns % 180 == 0) height else width
        val out = ByteArrayOutputStream(32 * 1024)
        YuvImage(rotated, ImageFormat.NV21, outWidth, outHeight, null)
            .compressToJpeg(Rect(0, 0, outWidth, outHeight), quality, out)
        return out.toByteArray()
    }

    private fun toNv21(image: Image): ByteArray {
        val width = image.width
        val height = image.height
        val out = ByteArray(width * height * 3 / 2)
        val yPlane = image.planes[0]
        val yBuffer = yPlane.buffer
        var position = 0
        for (row in 0 until height) {
            yBuffer.position(row * yPlane.rowStride)
            yBuffer.get(out, position, width)
            position += width
        }
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]
        val uBuffer = uPlane.buffer
        val vBuffer = vPlane.buffer
        for (row in 0 until height / 2) {
            for (column in 0 until width / 2) {
                out[position++] = vBuffer.get(row * vPlane.rowStride + column * vPlane.pixelStride)
                out[position++] = uBuffer.get(row * uPlane.rowStride + column * uPlane.pixelStride)
            }
        }
        return out
    }

    /** Clockwise, by [turns] degrees: the luma, then the (V, U) pairs. */
    private fun rotateNv21(source: ByteArray, width: Int, height: Int, turns: Int): ByteArray {
        if (turns == 0) return source
        val out = ByteArray(source.size)
        val outWidth = if (turns % 180 == 0) width else height
        for (y in 0 until height) {
            for (x in 0 until width) {
                val (nx, ny) = rotated(x, y, width, height, turns)
                out[ny * outWidth + nx] = source[y * width + x]
            }
        }
        val luma = width * height
        val chromaWidth = width / 2
        val chromaHeight = height / 2
        val outChromaWidth = outWidth / 2
        for (y in 0 until chromaHeight) {
            for (x in 0 until chromaWidth) {
                val (nx, ny) = rotated(x, y, chromaWidth, chromaHeight, turns)
                val from = luma + (y * chromaWidth + x) * 2
                val to = luma + (ny * outChromaWidth + nx) * 2
                out[to] = source[from]
                out[to + 1] = source[from + 1]
            }
        }
        return out
    }

    private fun rotated(x: Int, y: Int, width: Int, height: Int, turns: Int): Pair<Int, Int> =
        when (turns) {
            90 -> Pair(height - 1 - y, x)
            180 -> Pair(width - 1 - x, height - 1 - y)
            else -> Pair(y, width - 1 - x)
        }

    fun close() {
        wanted?.result?.success(null)
        wanted = null
        opening?.error("stopped", null, null)
        opening = null
        try {
            session?.close()
        } catch (e: Exception) {
            // Already closed.
        }
        session = null
        device?.close()
        device = null
        reader?.close()
        reader = null
        thread?.quitSafely()
        thread = null
        handler = null
    }
}
