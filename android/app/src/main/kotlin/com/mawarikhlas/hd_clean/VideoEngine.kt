package com.mawarikhlas.hd_clean

import android.content.Context
import android.media.MediaCodecInfo.CodecProfileLevel
import android.media.MediaCodecInfo.EncoderCapabilities
import android.opengl.GLES20
import android.os.Handler
import android.os.Looper
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.common.util.TimestampConsumer
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.FrameDropEffect
import androidx.media3.effect.Presentation
import androidx.media3.effect.TimestampAdjustment
import androidx.media3.transformer.AudioEncoderSettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.InAppMp4Muxer
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import java.io.File
import kotlin.math.max

/** Settings decided by the Dart planner (lib/engine/planner.dart). */
data class ExportRequest(
    val jobId: String,
    val input: String,
    val output: String,
    val width: Int,
    val height: Int,
    val frameMode: String,
    val fps: Double,
    val convertToCfr: Boolean,
    val videoCodec: String,
    val videoBitrate: Int,
    val keyframeIntervalSec: Double,
    val toneMapHdr: Boolean,
    val audioMode: String,
    val audioBitrate: Int,
    val audioSampleRate: Int,
    val remuxOnly: Boolean,
    val startMs: Long?,
    val endMs: Long?,
    val sourceChannels: Int?,
    val sourceFps: Double?,
    val sourceWidth: Int?,
    val sourceHeight: Int?,
    val durationMs: Long,
) {
    companion object {
        fun from(a: Map<String, Any?>) = ExportRequest(
            jobId = a["jobId"] as String,
            input = a["input"] as String,
            output = a["output"] as String,
            width = (a["width"] as Number).toInt(),
            height = (a["height"] as Number).toInt(),
            frameMode = a["frameMode"] as String,
            fps = (a["fps"] as Number).toDouble(),
            convertToCfr = a["convertToCfr"] as Boolean,
            videoCodec = a["videoCodec"] as String,
            videoBitrate = (a["videoBitrate"] as Number).toInt(),
            keyframeIntervalSec = (a["keyframeIntervalSec"] as Number).toDouble(),
            toneMapHdr = a["toneMapHdr"] as Boolean,
            audioMode = a["audioMode"] as String,
            audioBitrate = (a["audioBitrate"] as Number).toInt(),
            audioSampleRate = (a["audioSampleRate"] as Number).toInt(),
            remuxOnly = a["remuxOnly"] as Boolean,
            startMs = (a["startMs"] as Number?)?.toLong(),
            endMs = (a["endMs"] as Number?)?.toLong(),
            sourceChannels = (a["sourceChannels"] as Number?)?.toInt(),
            sourceFps = (a["sourceFps"] as Number?)?.toDouble(),
            sourceWidth = (a["sourceWidth"] as Number?)?.toInt(),
            sourceHeight = (a["sourceHeight"] as Number?)?.toInt(),
            durationMs = (a["durationMs"] as Number?)?.toLong() ?: 0L,
        )
    }
}

class EngineError(val code: String, message: String) : Exception(message)

/**
 * Maps each frame (1:1, as TimestampAdjustment requires) to the nearest free
 * slot of a constant-rate grid. Timestamps stay strictly increasing and within
 * one frame of their original time, so audio sync is preserved.
 */
@UnstableApi
class CfrTimestampMap(fps: Double) : TimestampAdjustment.TimestampMap {
    private val periodUs = 1_000_000.0 / fps
    private var lastSlot = Long.MIN_VALUE

    override fun calculateOutputTimeUs(inputTimeUs: Long, consumer: TimestampConsumer) {
        var slot = Math.round(inputTimeUs / periodUs)
        if (lastSlot != Long.MIN_VALUE && slot <= lastSlot) slot = lastSlot + 1
        lastSlot = slot
        consumer.onTimestamp(Math.round(slot * periodUs))
    }
}

@UnstableApi
class VideoEngine(private val context: Context) {

    private val main = Handler(Looper.getMainLooper())

    private class Job(
        val req: ExportRequest,
        val transformer: Transformer,
        val onDone: (Result<Map<String, Any?>>) -> Unit,
    ) {
        var finished = false
    }

    private val jobs = HashMap<String, Job>()

    /** Called on the main thread with (jobId, stage, percent). */
    var progressListener: ((String, String, Double) -> Unit)? = null

    fun export(req: ExportRequest, onDone: (Result<Map<String, Any?>>) -> Unit) {
        check(Looper.myLooper() == Looper.getMainLooper())
        val outFile = File(req.output)
        outFile.parentFile?.mkdirs()
        if (outFile.exists()) outFile.delete()

        var fallbackNote: String? = null
        val listener = object : Transformer.Listener {
            override fun onCompleted(composition: Composition, result: ExportResult) {
                val job = jobs.remove(req.jobId) ?: return
                if (job.finished) return
                job.finished = true
                val transmuxed = result.videoConversionProcess == ExportResult.CONVERSION_PROCESS_TRANSMUXED
                job.onDone(Result.success(mapOf(
                    "path" to req.output,
                    "sizeBytes" to outFile.length(),
                    "encoderName" to result.videoEncoderName,
                    "transmuxed" to transmuxed,
                    "fallback" to fallbackNote,
                )))
            }

            override fun onError(composition: Composition, result: ExportResult, exception: ExportException) {
                val job = jobs.remove(req.jobId) ?: return
                if (job.finished) return
                job.finished = true
                outFile.delete()
                job.onDone(Result.failure(EngineError("export_failed", friendlyMessage(exception, req))))
            }

            override fun onFallbackApplied(
                composition: Composition,
                originalTransformationRequest: androidx.media3.transformer.TransformationRequest,
                fallbackTransformationRequest: androidx.media3.transformer.TransformationRequest,
            ) {
                fallbackNote = "The encoder on this device adjusted some settings to ones it supports."
            }
        }

        val transformer = try {
            buildTransformer(req, listener)
        } catch (e: Exception) {
            onDone(Result.failure(EngineError("setup_failed", "Could not prepare the encoder: ${e.message}")))
            return
        }
        val job = Job(req, transformer, onDone)
        jobs[req.jobId] = job
        progressListener?.invoke(req.jobId, "preparing", -1.0)
        try {
            transformer.start(buildComposition(req), req.output)
        } catch (e: Exception) {
            jobs.remove(req.jobId)
            onDone(Result.failure(EngineError("setup_failed", "Could not start processing: ${e.message}")))
            return
        }
        pollProgress(job)
    }

    private fun pollProgress(job: Job) {
        val holder = ProgressHolder()
        val tick = object : Runnable {
            override fun run() {
                if (job.finished || !jobs.containsKey(job.req.jobId)) return
                val state = job.transformer.getProgress(holder)
                if (state == Transformer.PROGRESS_STATE_AVAILABLE) {
                    progressListener?.invoke(job.req.jobId, if (holder.progress > 0) "encoding" else "preparing", holder.progress.toDouble())
                } else if (state == Transformer.PROGRESS_STATE_WAITING_FOR_AVAILABILITY) {
                    progressListener?.invoke(job.req.jobId, "preparing", -1.0)
                }
                main.postDelayed(this, 250)
            }
        }
        main.post(tick)
    }

    fun cancel(jobId: String) {
        val job = jobs.remove(jobId) ?: return
        if (job.finished) return
        job.finished = true
        // Transformer does not invoke the listener after cancel(): resolve here.
        try { job.transformer.cancel() } catch (_: Exception) {}
        File(job.req.output).delete()
        job.onDone(Result.failure(EngineError("cancelled", "Cancelled")))
    }

    private fun buildTransformer(req: ExportRequest, listener: Transformer.Listener): Transformer {
        val b = Transformer.Builder(context)
            .addListener(listener)
            .setLooper(Looper.getMainLooper())
            // Encode rotated frames upright so no app relies on a rotation flag.
            .setPortraitEncodingEnabled(true)
            .setMuxerFactory(
                InAppMp4Muxer.Factory()
                    // Fast start: reserve room so moov is written before mdat.
                    .setAttemptStreamableOutputEnabled(true)
                    .setFreeSpaceAfterFileTypeBoxBytes(moovReserveBytes(req)),
            )
        if (!req.remuxOnly) {
            b.setVideoMimeType(if (req.videoCodec == "hevc") MimeTypes.VIDEO_H265 else MimeTypes.VIDEO_H264)
            if (req.audioMode == "transcode") b.setAudioMimeType(MimeTypes.AUDIO_AAC)
            val (profile, level) = profileLevel(req)
            val video = VideoEncoderSettings.Builder()
                .setBitrate(req.videoBitrate)
                .setBitrateMode(EncoderCapabilities.BITRATE_MODE_VBR)
                .setEncodingProfileLevel(profile, level)
                .setiFrameIntervalSeconds(req.keyframeIntervalSec.toFloat())
                .build()
            val audio = AudioEncoderSettings.Builder()
                .setProfile(CodecProfileLevel.AACObjectLC)
                .setBitrate(req.audioBitrate)
                .build()
            b.setEncoderFactory(
                DefaultEncoderFactory.Builder(context)
                    .setRequestedVideoEncoderSettings(video)
                    .setRequestedAudioEncoderSettings(audio)
                    // Prefer hardware; fall back to the closest supported settings
                    // instead of failing on devices with limited encoders.
                    .setEnableFallback(true)
                    .build(),
            )
        }
        return b.build()
    }

    /** ~32 bytes of index per sample (video + audio) plus headroom. */
    private fun moovReserveBytes(req: ExportRequest): Int {
        val seconds = ((req.endMs ?: req.durationMs) - (req.startMs ?: 0)).coerceAtLeast(1000) / 1000.0
        val samples = seconds * (req.fps + 47.0) // AAC: 48000 / 1024 ≈ 47 frames/s
        return (samples * 32 + 256 * 1024).toInt().coerceIn(256 * 1024, 24 * 1024 * 1024)
    }

    private fun profileLevel(req: ExportRequest): Pair<Int, Int> {
        val pixelsPerSec = req.width.toLong() * req.height * req.fps
        return if (req.videoCodec == "hevc") {
            CodecProfileLevel.HEVCProfileMain to when {
                pixelsPerSec <= 1920L * 1080 * 30 -> CodecProfileLevel.HEVCMainTierLevel4
                pixelsPerSec <= 1920L * 1080 * 60 -> CodecProfileLevel.HEVCMainTierLevel41
                pixelsPerSec <= 3840L * 2160 * 30 -> CodecProfileLevel.HEVCMainTierLevel5
                else -> CodecProfileLevel.HEVCMainTierLevel51
            }
        } else {
            CodecProfileLevel.AVCProfileHigh to when {
                pixelsPerSec <= 1280L * 720 * 30 -> CodecProfileLevel.AVCLevel31
                pixelsPerSec <= 1920L * 1080 * 30 -> CodecProfileLevel.AVCLevel4
                pixelsPerSec <= 1920L * 1080 * 60 -> CodecProfileLevel.AVCLevel42
                pixelsPerSec <= 3840L * 2160 * 30 -> CodecProfileLevel.AVCLevel51
                else -> CodecProfileLevel.AVCLevel52
            }
        }
    }

    private fun buildComposition(req: ExportRequest): Composition {
        val itemBuilder = MediaItem.Builder().setUri(VideoProbe.parse(req.input))
        if (req.startMs != null || req.endMs != null) {
            val clip = MediaItem.ClippingConfiguration.Builder()
            req.startMs?.let { clip.setStartPositionMs(it) }
            req.endMs?.let { clip.setEndPositionMs(it) }
            itemBuilder.setClippingConfiguration(clip.build())
        }

        val videoEffects = ArrayList<Effect>()
        val audioProcessors = ArrayList<AudioProcessor>()
        if (!req.remuxOnly) {
            val srcFps = req.sourceFps ?: 0.0
            if (req.convertToCfr || (srcFps > 0 && req.fps < srcFps - 0.05)) {
                // Drops frames at an even cadence to the target rate; also
                // regularises variable-frame-rate input.
                videoEffects.add(FrameDropEffect.createDefaultFrameDropEffect(req.fps.toFloat()))
            }
            // True constant frame rate: FrameDropEffect only drops frames and
            // keeps their original (irregular) timestamps, so every surviving
            // frame is then placed on an exact 1/fps grid.
            videoEffects.add(TimestampAdjustment(CfrTimestampMap(req.fps), SpeedProvider.DEFAULT))
            val layout = when (req.frameMode) {
                "fill" -> Presentation.LAYOUT_SCALE_TO_FIT_WITH_CROP
                else -> Presentation.LAYOUT_SCALE_TO_FIT // keep (same aspect) or fit (bars)
            }
            var presentation = Presentation.createForWidthAndHeight(req.width, req.height, layout)
            val srcLong = max(req.sourceWidth ?: 0, req.sourceHeight ?: 0)
            if (srcLong > max(req.width, req.height)) {
                // Mipmapped minification: prevents aliasing/shimmer when
                // downscaling (e.g. 4K → 1080p).
                presentation = presentation.copyWithTextureMinFilter(GLES20.GL_LINEAR_MIPMAP_LINEAR)
            }
            videoEffects.add(presentation)

            if (req.audioMode == "transcode") {
                val ch = req.sourceChannels ?: 2
                if (ch > 2) {
                    val mix = ChannelMixingAudioProcessor()
                    mix.putChannelMixingMatrix(ChannelMixingMatrix.createForConstantGain(ch, 2))
                    audioProcessors.add(mix)
                }
                audioProcessors.add(SonicAudioProcessor().apply { setOutputSampleRateHz(req.audioSampleRate) })
            }
        }

        val edited = EditedMediaItem.Builder(itemBuilder.build())
            .setRemoveAudio(req.audioMode == "none")
            .setEffects(Effects(audioProcessors, videoEffects))
            .build()
        val sequence = EditedMediaItemSequence.Builder(edited).build()
        val composition = Composition.Builder(sequence)
        if (req.toneMapHdr && !req.remuxOnly) {
            composition.setHdrMode(Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL)
        }
        if (req.remuxOnly) {
            composition.setTransmuxVideo(true)
            composition.setTransmuxAudio(true)
        } else if (req.audioMode == "copy") {
            composition.setTransmuxAudio(true)
        }
        return composition.build()
    }

    private fun friendlyMessage(e: ExportException, req: ExportRequest): String = when (e.errorCode) {
        ExportException.ERROR_CODE_IO_FILE_NOT_FOUND, ExportException.ERROR_CODE_IO_NO_PERMISSION ->
            "The original video can no longer be accessed. Please select it again."
        ExportException.ERROR_CODE_DECODER_INIT_FAILED, ExportException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED ->
            "This phone cannot decode this video's format (${e.message ?: "unsupported codec"})."
        ExportException.ERROR_CODE_ENCODER_INIT_FAILED, ExportException.ERROR_CODE_ENCODING_FORMAT_UNSUPPORTED ->
            if (req.width * req.height > 1920 * 1080)
                "This phone's encoder does not support ${req.width}×${req.height} at ${req.fps.toInt()} FPS. Try TikTok HD (1080p)."
            else "This phone's encoder rejected these settings. Try H.264 or a lower frame rate."
        ExportException.ERROR_CODE_MUXING_FAILED, ExportException.ERROR_CODE_IO_UNSPECIFIED ->
            if (File(req.output).parentFile?.usableSpace ?: Long.MAX_VALUE < 20L * 1024 * 1024)
                "Storage is full. Free some space and try again."
            else "Writing the video file failed (${e.errorCodeName})."
        else -> "Processing failed (${e.errorCodeName}). Your original video was not modified."
    }
}
