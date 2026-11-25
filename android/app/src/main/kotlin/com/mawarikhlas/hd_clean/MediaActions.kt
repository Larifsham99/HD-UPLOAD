package com.mawarikhlas.hd_clean

import android.app.Activity
import android.content.ClipData
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import java.io.File

object MediaActions {

    /** Copies the export into the shared gallery. The app's copy stays intact. */
    fun saveToGallery(ctx: Context, path: String) {
        val src = File(path)
        if (!src.exists()) throw EngineError("missing", "The optimized file no longer exists.")
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, src.name)
                put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/HD CLEAN")
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
            val resolver = ctx.contentResolver
            val uri = resolver.insert(MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values)
                ?: throw EngineError("save_failed", "Could not create the gallery entry.")
            try {
                resolver.openOutputStream(uri)?.use { out -> src.inputStream().use { it.copyTo(out, 1 shl 20) } }
                    ?: throw EngineError("save_failed", "Could not write to the gallery.")
                values.clear()
                values.put(MediaStore.Video.Media.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw if (e is EngineError) e else EngineError("save_failed", storageMessage(e))
            }
        } else {
            @Suppress("DEPRECATION")
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES), "HD CLEAN")
            dir.mkdirs()
            val dest = File(dir, src.name)
            try {
                src.copyTo(dest, overwrite = true)
            } catch (e: Exception) {
                dest.delete()
                throw EngineError("save_failed", storageMessage(e))
            }
            MediaScannerConnection.scanFile(ctx, arrayOf(dest.absolutePath), arrayOf("video/mp4"), null)
        }
    }

    private fun storageMessage(e: Exception) =
        if ((e.message ?: "").contains("ENOSPC") || (e.message ?: "").contains("No space"))
            "Not enough storage to save the video. Free some space and try again."
        else "Could not save the video: ${e.message}"

    private val packages = mapOf(
        "tiktok" to listOf("com.zhiliaoapp.musically", "com.ss.android.ugc.trill", "com.ss.android.ugc.aweme"),
        "instagram" to listOf("com.instagram.android"),
        "whatsapp" to listOf("com.whatsapp", "com.whatsapp.w4b"),
    )
    private val names = mapOf("tiktok" to "TikTok", "instagram" to "Instagram", "whatsapp" to "WhatsApp")

    /** Opens the Android Sharesheet, or the chosen app directly. */
    fun share(activity: Activity, path: String, target: String) {
        val file = File(path)
        if (!file.exists()) throw EngineError("missing", "The optimized file no longer exists.")
        val uri = FileProvider.getUriForFile(activity, activity.packageName + ".fileprovider", file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "video/mp4"
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newRawUri(file.name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val candidates = packages[target]
        if (candidates == null) {
            activity.startActivity(Intent.createChooser(send, "Share HD video"))
            return
        }
        val pm = activity.packageManager
        val installed = candidates.firstOrNull { pkg ->
            try { pm.getPackageInfo(pkg, 0); true } catch (_: Exception) { false }
        } ?: throw EngineError("not_installed", "${names[target]} is not installed on this phone. Use \"Share video\" instead.")
        send.setPackage(installed)
        activity.startActivity(send)
    }
}
