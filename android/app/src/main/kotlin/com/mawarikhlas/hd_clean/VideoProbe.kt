package com.mawarikhlas.hd_clean

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaCodecInfo.CodecProfileLevel
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

/** Reads real properties of a video file without decoding it. */
object VideoProbe {

    fun parse(uri: String): Uri =
        if (uri.startsWith("content://") || uri.startsWith("file://")) Uri.parse(uri) else Uri.fromFile(File(uri))

    private fun MediaFormat.num(key: String): Number? {
        if (!containsKey(key)) return null
        return try {
            getInteger(key)
        } catch (_: Exception) {
            try { getFloat(key) } catch (_: Exception) { null }
        }
    }

    private fun nameAndSize(ctx: Context, uri: Uri): Pair<String, Long> {
        if (uri.scheme == "file") {
            val f = File(uri.path!!)
            return f.name to f.length()
        }
        var name = "video.mp4"
        var size = -1L
        ctx.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                c.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }?.let { c.getString(it)?.let { n -> name = n } }
                c.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 }?.let { if (!c.isNull(it)) size = c.getLong(it) }
            }
        }
        if (size < 0) {
            ctx.contentResolver.openAssetFileDescriptor(uri, "r")?.use { size = it.length }
        }
        return name to size
    }

    fun probe(ctx: Context, uriString: String): Map<String, Any?> {
        val uri = parse(uriString)
        val (name, size) = nameAndSize(ctx, uri)
        val out = HashMap<String, Any?>()
        out["uri"] = uriString
        out["name"] = name
        out["sizeBytes"] = size

        val mmr = MediaMetadataRetriever()
        try {
            mmr.setDataSource(ctx, uri)
            val durationMs = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            out["durationMs"] = durationMs
            out["rotation"] = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            out["containerBitrate"] = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toIntOrNull()
            if (Build.VERSION.SDK_INT >= 28) {
                val frames = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)?.toLongOrNull()
                if (frames != null && durationMs > 0) out["frameCountFps"] = frames * 1000.0 / durationMs
            }
        } finally {
            mmr.release()
        }

        val ex = MediaExtractor()
        try {
            ex.setDataSource(ctx, uri, null)
            var videoTrack = -1
            var audioBitrate: Int? = null
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/") && videoTrack < 0) {
                    videoTrack = i
                    out["videoCodec"] = mime
                    out["width"] = f.num(MediaFormat.KEY_WIDTH)?.toInt() ?: 0
                    out["height"] = f.num(MediaFormat.KEY_HEIGHT)?.toInt() ?: 0
                    f.num(MediaFormat.KEY_FRAME_RATE)?.toDouble()?.let { out["fps"] = it }
                    f.num(MediaFormat.KEY_BIT_RATE)?.toInt()?.let { out["videoBitrate"] = it }
                    val transfer = f.num(MediaFormat.KEY_COLOR_TRANSFER)?.toInt()
                    val profile = f.num(MediaFormat.KEY_PROFILE)?.toInt()
                    var bitDepth = 8
                    var hdr: String? = null
                    when (transfer) {
                        MediaFormat.COLOR_TRANSFER_ST2084 -> hdr = "HDR10"
                        MediaFormat.COLOR_TRANSFER_HLG -> hdr = "HLG"
                    }
                    if (mime == MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION) hdr = "Dolby Vision"
                    if (mime == MediaFormat.MIMETYPE_VIDEO_HEVC && profile != null) {
                        when (profile) {
                            CodecProfileLevel.HEVCProfileMain10 -> bitDepth = 10
                            CodecProfileLevel.HEVCProfileMain10HDR10 -> { bitDepth = 10; hdr = hdr ?: "HDR10" }
                            CodecProfileLevel.HEVCProfileMain10HDR10Plus -> { bitDepth = 10; hdr = "HDR10+" }
                        }
                        out["videoProfile"] = when (profile) {
                            CodecProfileLevel.HEVCProfileMain -> "Main"
                            CodecProfileLevel.HEVCProfileMain10, CodecProfileLevel.HEVCProfileMain10HDR10,
                            CodecProfileLevel.HEVCProfileMain10HDR10Plus -> "Main 10"
                            else -> null
                        }
                    }
                    if (mime == MediaFormat.MIMETYPE_VIDEO_AVC && profile != null) {
                        out["videoProfile"] = when (profile) {
                            CodecProfileLevel.AVCProfileBaseline, CodecProfileLevel.AVCProfileConstrainedBaseline -> "Baseline"
                            CodecProfileLevel.AVCProfileMain -> "Main"
                            CodecProfileLevel.AVCProfileHigh, CodecProfileLevel.AVCProfileConstrainedHigh -> "High"
                            CodecProfileLevel.AVCProfileHigh10 -> { bitDepth = 10; "High 10" }
                            else -> null
                        }
                    }
                    if (hdr != null) bitDepth = max(bitDepth, 10)
                    out["hdr"] = hdr
                    out["bitDepth"] = bitDepth
                } else if (mime.startsWith("audio/") && out["audioCodec"] == null) {
                    out["hasAudio"] = true
                    out["audioCodec"] = mime
                    out["audioSampleRate"] = f.num(MediaFormat.KEY_SAMPLE_RATE)?.toInt()
                    out["audioChannels"] = f.num(MediaFormat.KEY_CHANNEL_COUNT)?.toInt()
                    audioBitrate = f.num(MediaFormat.KEY_BIT_RATE)?.toInt()
                    out["audioBitrate"] = audioBitrate
                }
            }
            if (videoTrack < 0) throw IllegalArgumentException("This file has no video track.")
            if (out["hasAudio"] == null) out["hasAudio"] = false

            analyseTiming(ex, videoTrack, (out["durationMs"] as Long), out)
        } finally {
            ex.release()
        }

        // Average fps: frame-count based is the most reliable on Android.
        val fc = out["frameCountFps"] as Double?
        val measured = out["measuredFps"] as Double?
        out["fps"] = fc ?: measured ?: (out["fps"] as Double?) ?: 30.0

        if (out["videoBitrate"] == null) {
            val dur = out["durationMs"] as Long
            val container = (out["containerBitrate"] as Int?)
                ?: if (dur > 0 && size > 0) (size * 8 * 1000 / dur).toInt() else 0
            out["videoBitrate"] = max(0, container - ((out["audioBitrate"] as Int?) ?: if (out["hasAudio"] == true) 128000 else 0))
        }
        return out
    }

    /**
     * Reads presentation timestamps of up to ~600 samples (start and middle of
     * the video) and measures frame interval spread. Phones and screen
     * recorders often produce variable frame rate, which causes stutter and
     * audio drift after a platform re-encodes the video.
     */
    private fun analyseTiming(ex: MediaExtractor, track: Int, durationMs: Long, out: HashMap<String, Any?>) {
        ex.selectTrack(track)
        val deltas = ArrayList<Long>()
        fun window(seekUs: Long) {
            if (seekUs > 0) ex.seekTo(seekUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val times = ArrayList<Long>()
            while (times.size < 300) {
                val t = ex.sampleTime
                if (t < 0) break
                times.add(t)
                if (!ex.advance()) break
            }
            times.sort() // decode order → presentation order (B-frames)
            for (i in 1 until times.size) {
                val d = times[i] - times[i - 1]
                if (d > 0) deltas.add(d)
            }
        }
        window(0)
        if (durationMs > 20_000) window(durationMs * 500)
        if (deltas.size < 10) return
        val sorted = deltas.sorted()
        val median = sorted[sorted.size / 2].toDouble()
        val p5 = sorted[(sorted.size * 0.05).toInt()].toDouble()
        val p95 = sorted[(sorted.size * 0.95).toInt().coerceAtMost(sorted.size - 1)].toDouble()
        val irregular = deltas.count { abs(it - median) > median * 0.25 }
        out["measuredFps"] = ((1_000_000.0 / (deltas.average())) * 100).roundToInt() / 100.0
        out["minFps"] = 1_000_000.0 / p95
        out["maxFps"] = 1_000_000.0 / p5
        out["isVfr"] = irregular > deltas.size * 0.05 || (p95 - p5) > median * 0.3
    }

    fun frame(ctx: Context, uriString: String, timeMs: Long, maxSize: Int, exact: Boolean): ByteArray {
        val mmr = MediaMetadataRetriever()
        try {
            mmr.setDataSource(ctx, parse(uriString))
            val option = if (exact) MediaMetadataRetriever.OPTION_CLOSEST else MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            val us = timeMs * 1000
            val bmp: Bitmap = (if (Build.VERSION.SDK_INT >= 27) mmr.getScaledFrameAtTime(us, option, maxSize, maxSize)
            else mmr.getFrameAtTime(us, option)?.let { scale(it, maxSize) })
                ?: throw IllegalStateException("Could not read a frame from this video.")
            val bos = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.JPEG, 92, bos)
            bmp.recycle()
            return bos.toByteArray()
        } finally {
            mmr.release()
        }
    }

    private fun scale(b: Bitmap, maxSize: Int): Bitmap {
        val s = maxSize.toFloat() / max(b.width, b.height)
        if (s >= 1f) return b
        return Bitmap.createScaledBitmap(b, (b.width * s).roundToInt(), (b.height * s).roundToInt(), true)
    }
}
