package com.dismessage.dismessage

import android.app.Activity
import android.app.DownloadManager
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.Executors

/**
 * Files sent directly between peers, with the platform APIs only (no extra
 * Gradle dependency). Channel "dismessage/files".
 *
 * Sending: the system picker (ACTION_OPEN_DOCUMENT), then the file is read
 * chunk by chunk. Receiving: written as it arrives into Downloads/Dismessage
 * through MediaStore (hidden while pending), or into the app's own
 * Downloads folder before Android 10.
 */
class FileHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val PICK_REQUEST = 4209
        private const val SUBFOLDER = "Dismessage"
    }

    private class Output(
        val stream: OutputStream,
        val uri: Uri?,
        val file: File?,
        val name: String,
    )

    /** The screen, when the app is shown: needed to open the picker. */
    var activity: Activity? = null

    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val inputs = HashMap<Int, InputStream>()
    private val outputs = HashMap<Int, Output>()
    private var nextHandle = 1
    private var pendingPick: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> pick(result)
            "read" -> background(result) {
                read(call.argument<Int>("handle")!!, call.argument<Int>("length")!!)
            }
            "closeRead" -> background(result) {
                synchronized(inputs) { inputs.remove(call.argument<Int>("handle")!!) }?.close()
                null
            }
            "create" -> background(result) { create(call.argument<String>("name")!!) }
            "write" -> background(result) {
                val output = synchronized(outputs) { outputs[call.argument<Int>("handle")!!] }
                    ?: throw IllegalStateException("closed")
                output.stream.write(call.argument<ByteArray>("bytes")!!)
                null
            }
            "finish" -> background(result) { finish(call.argument<Int>("handle")!!) }
            "abort" -> background(result) {
                abort(call.argument<Int>("handle")!!)
                null
            }
            "open" -> result.success(open(Uri.parse(call.argument<String>("uri")!!)))
            // A web link from "À propos": only http(s), opened in the browser.
            "openUrl" -> {
                val url = Uri.parse(call.argument<String>("url")!!)
                result.success(
                    (url.scheme == "https" || url.scheme == "http") &&
                        start(Intent(Intent.ACTION_VIEW, url)),
                )
            }
            "showDownloads" -> result.success(
                start(Intent(DownloadManager.ACTION_VIEW_DOWNLOADS)),
            )
            else -> result.notImplemented()
        }
    }

    /** Disk and content I/O off the main thread; the answer comes back on it. */
    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("files", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    private fun pick(result: MethodChannel.Result) {
        val screen = activity
        if (screen == null) {
            result.error("files", "Application non affichée", null)
            return
        }
        pendingPick?.success(null)
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
        try {
            screen.startActivityForResult(intent, PICK_REQUEST)
        } catch (e: ActivityNotFoundException) {
            pendingPick = null
            result.error("files", "Aucun sélecteur de fichiers", null)
        }
    }

    /** Called by MainActivity with the picker's answer. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_REQUEST) return false
        val result = pendingPick ?: return true
        pendingPick = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        background(result) { opened(uri) }
        return true
    }

    private fun opened(uri: Uri): Map<String, Any> {
        val resolver = context.contentResolver
        var name: String? = null
        var size = -1L
        resolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameColumn >= 0) name = cursor.getString(nameColumn)
                if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) size = cursor.getLong(sizeColumn)
            }
        }
        if (size < 0) {
            size = resolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: -1L
        }
        if (size < 0) throw IllegalStateException("Taille du fichier inconnue")
        if (size > Int.MAX_VALUE) throw IllegalStateException("Fichier trop volumineux")
        val stream = resolver.openInputStream(uri)
            ?: throw IllegalStateException("Fichier illisible")
        val handle = synchronized(inputs) {
            val id = nextHandle++
            inputs[id] = stream
            id
        }
        return mapOf(
            "handle" to handle,
            "name" to (name ?: uri.lastPathSegment ?: "fichier"),
            "size" to size.toInt(),
        )
    }

    /** Reads the next [length] bytes (chunks are read in order). */
    private fun read(handle: Int, length: Int): ByteArray {
        val stream = synchronized(inputs) { inputs[handle] }
            ?: throw IllegalStateException("closed")
        val buffer = ByteArray(length)
        var filled = 0
        while (filled < length) {
            val count = stream.read(buffer, filled, length - filled)
            if (count < 0) break
            filled += count
        }
        return if (filled == length) buffer else buffer.copyOf(filled)
    }

    private fun mimeOf(name: String): String {
        val extension = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: "application/octet-stream"
    }

    private fun create(name: String): Map<String, Any> {
        val mime = mimeOf(name)
        val output: Output
        var finalName = name
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(
                    MediaStore.Downloads.RELATIVE_PATH,
                    "${Environment.DIRECTORY_DOWNLOADS}/$SUBFOLDER",
                )
                // Hidden from other apps until complete.
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("Téléchargements indisponibles")
            val stream = resolver.openOutputStream(uri)
            if (stream == null) {
                resolver.delete(uri, null, null)
                throw IllegalStateException("Téléchargements indisponibles")
            }
            output = Output(stream, uri, null, name)
        } else {
            // Android 9 and older: the public folder needs a permission;
            // the app's own Downloads folder does not.
            val dir = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                ?: context.filesDir
            dir.mkdirs()
            finalName = uniqueName(dir, name)
            val file = File(dir, finalName)
            output = Output(file.outputStream(), null, file, finalName)
        }
        val handle = synchronized(outputs) {
            val id = nextHandle++
            outputs[id] = output
            id
        }
        return mapOf("handle" to handle, "name" to finalName)
    }

    private fun uniqueName(dir: File, name: String): String {
        if (!File(dir, name).exists()) return name
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val extension = if (dot > 0) name.substring(dot) else ""
        var n = 2
        while (File(dir, "$stem ($n)$extension").exists()) n++
        return "$stem ($n)$extension"
    }

    private fun finish(handle: Int): Map<String, Any?> {
        val output = synchronized(outputs) { outputs.remove(handle) }
            ?: throw IllegalStateException("closed")
        output.stream.close()
        val uri = output.uri
        if (uri == null) {
            return mapOf(
                "uri" to null,
                "name" to output.name,
                "location" to "le dossier de Dismessage",
            )
        }
        val resolver = context.contentResolver
        resolver.update(
            uri,
            ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) },
            null,
            null,
        )
        // MediaStore renames the file if the name is taken.
        var name: String? = null
        resolver.query(uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null)
            ?.use { cursor -> if (cursor.moveToFirst()) name = cursor.getString(0) }
        return mapOf(
            "uri" to uri.toString(),
            "name" to (name ?: output.name),
            "location" to "Téléchargements/$SUBFOLDER",
        )
    }

    private fun abort(handle: Int) {
        val output = synchronized(outputs) { outputs.remove(handle) } ?: return
        try {
            output.stream.close()
        } catch (_: Exception) {
        }
        output.uri?.let { context.contentResolver.delete(it, null, null) }
        output.file?.delete()
    }

    private fun open(uri: Uri): Boolean {
        val mime = context.contentResolver.getType(uri) ?: "*/*"
        return start(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, mime)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
        )
    }

    private fun start(intent: Intent): Boolean = try {
        val screen = activity
        if (screen != null) {
            screen.startActivity(intent)
        } else {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        true
    } catch (e: ActivityNotFoundException) {
        false
    }
}
