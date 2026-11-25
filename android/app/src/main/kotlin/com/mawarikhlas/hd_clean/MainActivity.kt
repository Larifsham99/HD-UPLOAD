package com.mawarikhlas.hd_clean

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.MediaStore
import android.view.WindowManager
import androidx.media3.common.util.UnstableApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

@UnstableApi
class MainActivity : FlutterActivity() {

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newFixedThreadPool(2)
    private lateinit var engine: VideoEngine
    private var events: EventChannel.EventSink? = null

    private var pendingPick: MethodChannel.Result? = null
    private var pendingSave: Pair<String, MethodChannel.Result>? = null
    private var activeJobs = 0

    companion object {
        private const val PICK = 4101
        private const val PERM_STORAGE = 4102
        private const val PERM_NOTIFY = 4103
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        engine = VideoEngine(applicationContext)
        engine.progressListener = { jobId, stage, percent ->
            events?.success(mapOf("jobId" to jobId, "stage" to stage, "percent" to percent))
            ExportService.update(applicationContext, if (percent < 0) -1 else percent.toInt())
        }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "hdclean/progress").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) { events = sink }
            override fun onCancel(arguments: Any?) { events = null }
        })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hdclean/engine").setMethodCallHandler(::onCall)
    }

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        io.execute {
            try {
                val v = block()
                main.post { result.success(v) }
            } catch (e: EngineError) {
                main.post { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                main.post { result.error("error", e.message ?: e.javaClass.simpleName, null) }
            } catch (e: OutOfMemoryError) {
                main.post { result.error("oom", "Not enough memory to complete this step.", null) }
            }
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickVideo" -> pick(result)
            "probe" -> background(result) {
                try {
                    VideoProbe.probe(applicationContext, call.argument<String>("uri")!!)
                } catch (e: SecurityException) {
                    throw EngineError("no_access", "HD CLEAN no longer has access to this video. Please select it again.")
                } catch (e: EngineError) {
                    throw e
                } catch (e: Exception) {
                    throw EngineError("probe_failed", "This file could not be read as a video (${e.message}).")
                }
            }
            "frame" -> background(result) {
                VideoProbe.frame(
                    applicationContext,
                    call.argument<String>("uri")!!,
                    (call.argument<Number>("timeMs") ?: 0).toLong(),
                    (call.argument<Number>("maxSize") ?: 512).toInt(),
                    call.argument<Boolean>("exact") ?: false,
                )
            }
            "export" -> {
                val req = ExportRequest.from(call.arguments as Map<String, Any?>)
                requestNotificationsOnce()
                activeJobs++
                ExportService.start(applicationContext)
                engine.export(req) { r ->
                    activeJobs = (activeJobs - 1).coerceAtLeast(0)
                    if (activeJobs == 0) ExportService.stop(applicationContext)
                    r.onSuccess { result.success(it) }
                        .onFailure { e ->
                            val code = (e as? EngineError)?.code ?: "error"
                            result.error(code, e.message, null)
                        }
                }
            }
            "cancel" -> {
                engine.cancel(call.argument<String>("jobId")!!)
                result.success(null)
            }
            "freeSpace" -> result.success(StatFs(filesDir.absolutePath).availableBytes)
            "saveToGallery" -> {
                val path = call.argument<String>("path")!!
                if (Build.VERSION.SDK_INT < 29 &&
                    checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
                ) {
                    pendingSave = path to result
                    requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), PERM_STORAGE)
                } else {
                    background(result) { MediaActions.saveToGallery(applicationContext, path); null }
                }
            }
            "share" -> try {
                MediaActions.share(this, call.argument<String>("path")!!, call.argument<String>("target") ?: "any")
                result.success(null)
            } catch (e: EngineError) {
                result.error(e.code, e.message, null)
            } catch (e: Exception) {
                result.error("share_failed", "Could not open sharing: ${e.message}", null)
            }
            "keepAwake" -> {
                if (call.argument<Boolean>("on") == true) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private var askedNotifications = false
    private fun requestNotificationsOnce() {
        if (askedNotifications || Build.VERSION.SDK_INT < 33) return
        askedNotifications = true
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERM_NOTIFY)
        }
    }

    @SuppressLint("InlinedApi")
    private fun pick(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "The picker is already open.", null)
            return
        }
        pendingPick = result
        // Android 13+: system Photo Picker (no storage permission needed).
        // Older: Storage Access Framework document picker.
        val intent = if (Build.VERSION.SDK_INT >= 33) {
            Intent(MediaStore.ACTION_PICK_IMAGES).apply { type = "video/*" }
        } else {
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "video/*"
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            }
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, PICK)
        } catch (e: Exception) {
            pendingPick = null
            result.error("picker_failed", "Could not open the video picker: ${e.message}", null)
        }
    }

    @Deprecated("Uses the platform activity result API")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK) return
        val r = pendingPick ?: return
        pendingPick = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            r.success(null)
            return
        }
        // Keep access so history and Before/After keep working after restarts.
        try {
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: Exception) {
        }
        r.success(uri.toString())
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PERM_STORAGE) return
        val (path, result) = pendingSave ?: return
        pendingSave = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            background(result) { MediaActions.saveToGallery(applicationContext, path); null }
        } else {
            result.error("permission_denied", "Storage permission is needed to save to the gallery on this Android version.", null)
        }
    }

    override fun onDestroy() {
        ExportService.stop(applicationContext)
        io.shutdown()
        super.onDestroy()
    }
}
