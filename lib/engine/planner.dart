// The HD CLEAN smart encoding planner.
//
// Given a probed source and the user's choices, it decides every encoding
// parameter and explains each decision. It never upscales unless the user
// explicitly asks for the 1080p upload tier, never stretches, and avoids
// re-encoding when the source is already an optimal upload master.

import 'dart:math' as math;

import 'models.dart';
import 'presets.dart';

class PlanOptions {
  const PlanOptions({
    required this.preset,
    this.quality = QualityMode.balanced,
    this.frameMode = FrameMode.keep,
    this.allowUpscaleTo1080 = false,
    this.forceReencode = false,
    this.codec = 'h264',
    this.splitForStatus = true,
    this.statusSegmentSec,
    this.customShortEdge,
    this.customFps,
    this.customBitrate,
    this.customAudioBitrate,
  });

  final Preset preset;
  final QualityMode quality;
  final FrameMode frameMode;

  /// For sub-1080p sources: export at 1080p so the platform places the video
  /// in its 1080p quality tier. Does not recover detail.
  final bool allowUpscaleTo1080;
  final bool forceReencode;

  /// 'h264' or 'hevc' (HEVC only honoured where the preset allows it).
  final String codec;
  final bool splitForStatus;
  final int? statusSegmentSec;

  // Custom mode only. null = automatic / source.
  final int? customShortEdge;
  final double? customFps;
  final int? customBitrate;
  final int? customAudioBitrate;

  PlanOptions copyWith({
    Preset? preset,
    QualityMode? quality,
    FrameMode? frameMode,
    bool? allowUpscaleTo1080,
    bool? forceReencode,
    String? codec,
    bool? splitForStatus,
    int? statusSegmentSec,
    int? Function()? customShortEdge,
    double? Function()? customFps,
    int? Function()? customBitrate,
    int? Function()? customAudioBitrate,
  }) =>
      PlanOptions(
        preset: preset ?? this.preset,
        quality: quality ?? this.quality,
        frameMode: frameMode ?? this.frameMode,
        allowUpscaleTo1080: allowUpscaleTo1080 ?? this.allowUpscaleTo1080,
        forceReencode: forceReencode ?? this.forceReencode,
        codec: codec ?? this.codec,
        splitForStatus: splitForStatus ?? this.splitForStatus,
        statusSegmentSec: statusSegmentSec ?? this.statusSegmentSec,
        customShortEdge:
            customShortEdge != null ? customShortEdge() : this.customShortEdge,
        customFps: customFps != null ? customFps() : this.customFps,
        customBitrate:
            customBitrate != null ? customBitrate() : this.customBitrate,
        customAudioBitrate: customAudioBitrate != null
            ? customAudioBitrate()
            : this.customAudioBitrate,
      );
}

class PlanResult {
  const PlanResult({
    required this.plan,
    required this.parts,
    required this.estimatedBytes,
    required this.decisions,
    required this.alreadyOptimized,
  });

  final EncodePlan plan;

  /// One plan per output file (more than one when splitting for Status).
  final List<EncodePlan> parts;
  final int estimatedBytes;
  final List<String> decisions;
  final bool alreadyOptimized;
}

class PlannerException implements Exception {
  PlannerException(this.message);
  final String message;
  @override
  String toString() => message;
}

const _standardRates = [23.976, 24.0, 25.0, 29.97, 30.0, 48.0, 50.0, 59.94, 60.0, 90.0, 100.0, 120.0];

/// Snap a measured average frame rate to the nearest broadcast standard.
double snapFps(double fps) {
  if (fps <= 0) return 30;
  var best = _standardRates.first;
  for (final r in _standardRates) {
    if ((r - fps).abs() < (best - fps).abs()) best = r;
  }
  return (best - fps).abs() <= math.max(0.6, fps * 0.03) ? best : fps.roundToDouble();
}

/// Highest frame rate ≤ [max] that is an even division of [source], so frames
/// are dropped at a regular cadence (no judder). Falls back to [max].
double targetFps(double source, double max) {
  if (source <= max + 0.01) return source;
  for (var d = 2; d <= 5; d++) {
    final f = source / d;
    if (f <= max + 0.01 && f >= 23.9) return f;
  }
  return max;
}

int _even(num v) => math.max(2, (v / 2).round() * 2);

class _Geometry {
  _Geometry(this.w, this.h, this.cw, this.ch, this.mode, this.upscaled);
  final int w, h, cw, ch;
  final FrameMode mode;
  final bool upscaled;
}

_Geometry _geometry(VideoInfo s, int shortEdge, int longEdge, FrameMode mode,
    bool allowUp, List<String> notes) {
  final dw = s.displayWidth.toDouble(), dh = s.displayHeight.toDouble();
  // Keep mode follows the source orientation; 9:16 modes always use a portrait canvas.
  final portraitBox = mode == FrameMode.keep ? s.isPortrait : true;
  final bw = (portraitBox ? shortEdge : longEdge).toDouble();
  final bh = (portraitBox ? longEdge : shortEdge).toDouble();

  var effective = mode;
  var tolerance = 1.0001;
  final aspectDiff = ((dw / dh) - (bw / bh)).abs() / (bw / bh);
  if (mode != FrameMode.keep && aspectDiff < 0.005) {
    effective = FrameMode.keep;
  } else if (mode == FrameMode.keep && aspectDiff > 0 && aspectDiff < 0.02) {
    // Within 2% of the platform ratio (e.g. 1080×1916): match exactly with an
    // invisible crop rather than a slightly-off frame the platform would pad.
    effective = FrameMode.fill;
    tolerance = 1.012; // ≤1.2% resample to hit the exact size: invisible, not an upscale
    notes.add('Aspect ratio within 2% of ${bw ~/ 1}×${bh ~/ 1} — matched exactly with a ≤2% edge trim.');
  }

  double scale;
  switch (effective) {
    case FrameMode.keep:
      scale = math.min(bw / dw, bh / dh);
    case FrameMode.fit:
      scale = math.min(bw / dw, bh / dh);
    case FrameMode.fill:
      scale = math.max(bw / dw, bh / dh);
  }
  var upscaled = false;
  if (scale > tolerance && !allowUp) {
    // Never upscale: shrink the canvas instead so the picture stays native.
    final shrink = 1 / scale;
    if (effective == FrameMode.keep) {
      return _Geometry(_even(dw), _even(dh), _even(dw), _even(dh), effective, false);
    }
    final w = _even(bw * shrink), h = _even(bh * shrink);
    return _Geometry(w, h, _even(dw), _even(dh), effective, false);
  }
  if (scale > tolerance) upscaled = true;
  final cw = _even(dw * scale), ch = _even(dh * scale);
  if (effective == FrameMode.keep) {
    return _Geometry(cw, ch, cw, ch, effective, upscaled);
  }
  return _Geometry(_even(bw), _even(bh), cw, ch, effective, upscaled);
}

PlanResult planEncode(VideoInfo s, PlanOptions o) {
  final p = o.preset;
  final notes = <String>[];
  final isCustom = p.id == PresetId.custom;

  if (p.id == PresetId.tiktok4k && s.shortSide < 2000) {
    throw PlannerException(
        '4K export needs a 4K source. This video is ${s.width}×${s.height}; '
        'upscaling would not add real detail. Use TikTok HD instead.');
  }

  // ---------- Resolution ----------
  var shortEdge = p.shortEdge, longEdge = p.longEdge;
  if (isCustom && o.customShortEdge != null) {
    shortEdge = o.customShortEdge!;
    longEdge = (shortEdge * 16 / 9).round();
  }
  final wantsUpscale = o.allowUpscaleTo1080 && s.shortSide < shortEdge;
  final g = _geometry(s, shortEdge, longEdge, o.frameMode, wantsUpscale, notes);
  if (g.upscaled) {
    notes.add('Exported at ${g.w}×${g.h} to enter the platform\'s 1080p quality tier. '
        'This does not add detail that was not in the ${s.resolutionLabel} original.');
  } else if (s.shortSide < shortEdge * 0.95) {
    notes.add('Native ${s.displayWidth}×${s.displayHeight} kept — HD CLEAN never upscales by default.');
  } else if (g.cw < s.displayWidth || g.ch < s.displayHeight) {
    notes.add('Downscaled ${s.displayWidth}×${s.displayHeight} → ${g.cw}×${g.ch} once, on-device, '
        'with a high-quality filter (avoids a second resize by the platform).');
  }
  if (g.mode == FrameMode.fit && (g.cw != g.w || g.ch != g.h)) {
    notes.add('Whole picture kept inside a 9:16 frame (bars added, nothing stretched).');
  } else if (g.mode == FrameMode.fill && o.frameMode == FrameMode.fill) {
    notes.add('Picture fills the 9:16 frame; edges outside the frame are cropped (no stretching).');
  }
  if (s.rotation != 0) {
    notes.add('Rotation metadata (${s.rotation}°) is applied to the pixels so every app shows the correct orientation.');
  }

  // ---------- Frame rate ----------
  final srcFps = snapFps(s.fps);
  var fps = targetFps(srcFps, p.maxFps);
  if (isCustom && o.customFps != null) {
    fps = math.min(o.customFps!, srcFps);
    if (o.customFps! > srcFps + 0.1) {
      notes.add('Frame rate capped at the source\'s ${formatFps(srcFps)} — extra frames would be duplicates.');
    }
  }
  final fpsChanged = (fps - srcFps).abs() > 0.05;
  final cfr = s.isVfr || fpsChanged;
  if (s.isVfr) {
    notes.add('Variable frame rate converted to constant ${formatFps(fps)} for smooth playback and stable audio sync.');
  } else if (fpsChanged) {
    notes.add('${formatFps(srcFps)} → ${formatFps(fps)} (even frame cadence, no judder).');
  } else {
    notes.add('Original ${formatFps(srcFps)} preserved.');
  }

  // ---------- Codec ----------
  final codec = (p.allowHevc && o.codec == 'hevc') ? 'hevc' : 'h264';

  // ---------- Video bitrate ----------
  final range = fps > 31 ? p.rate60 : p.rate30;
  final presetPixels = p.shortEdge * p.longEdge;
  final contentPixels = math.min(g.cw, g.w) * math.min(g.ch, g.h);
  final pixelScale = math.pow(math.min(1.0, contentPixels / presetPixels), 0.75).toDouble();
  final codecScale = codec == 'hevc' ? 1 / codecEfficiency('hevc') : 1.0;

  final bpp = s.h264EquivalentBpp;
  final complexity = bpp <= 0 ? 0.6 : ((bpp - 0.05) / 0.20).clamp(0.0, 1.0);
  double base;
  switch (o.quality) {
    case QualityMode.maximum:
      base = range.max.toDouble();
    case QualityMode.balanced:
      base = range.min + (range.max - range.min) * (0.3 + 0.5 * complexity);
    case QualityMode.smaller:
      base = range.small.toDouble();
  }
  final floor = (o.quality == QualityMode.smaller ? range.small : range.min) * pixelScale * codecScale;
  var bitrate = base * pixelScale * codecScale;

  // Bits the source never had cannot be recovered: cap relative to source.
  final srcRate = s.effectiveVideoBitrate;
  if (srcRate > 0) {
    final pixelRatio = math.min(1.0, contentPixels / s.pixels);
    final srcEquivalent = srcRate * codecEfficiency(s.videoCodec) / codecEfficiency(codec) *
        math.pow(pixelRatio, 0.75) * (fps / math.max(fps, srcFps));
    final cap = math.max(floor, srcEquivalent * (o.quality == QualityMode.maximum ? 2.0 : 1.6));
    if (bitrate > cap) {
      bitrate = cap;
      notes.add('Bitrate limited to ${formatBitrate(cap)}: the source only carries about '
          '${formatBitrate(srcEquivalent)} of real detail at this size.');
    }
  }
  if (isCustom && o.customBitrate != null) bitrate = o.customBitrate!.toDouble();
  final videoBitrate = (bitrate / 100000).round() * 100000;

  // ---------- HDR ----------
  final toneMap = s.isHdr || s.bitDepth > 8;
  if (s.isHdr) {
    notes.add('${s.hdr} HDR tone-mapped to SDR BT.709 so it does not look washed-out or over-bright after upload.');
  } else if (s.bitDepth > 8) {
    notes.add('${s.bitDepth}-bit colour converted to 8-bit 4:2:0 BT.709, the format platforms ingest.');
  }

  // ---------- Audio ----------
  var audioTarget = isCustom && o.customAudioBitrate != null
      ? o.customAudioBitrate!
      : (o.quality == QualityMode.smaller ? 160000 : p.audioBitrate);
  String audioMode;
  if (!s.hasAudio) {
    audioMode = 'none';
  } else if (s.audioCodec == 'aac' &&
      s.audioSampleRate == 48000 &&
      (s.audioChannels ?? 2) <= 2 &&
      ((s.audioBitrate ?? 0) == 0 || s.audioBitrate! >= 96000) &&
      !(isCustom && o.customAudioBitrate != null)) {
    // Re-encoding AAC can only lose quality; a higher bitrate does not
    // restore what the first encode removed.
    audioMode = 'copy';
    audioTarget = s.audioBitrate ?? audioTarget;
    notes.add('Audio is already AAC 48 kHz — copied untouched (no generation loss).');
  } else {
    audioMode = 'transcode';
    notes.add('Audio → AAC-LC ${audioTarget ~/ 1000} kbps, 48 kHz.');
  }

  // ---------- Already optimal? ----------
  final segmentSec = o.statusSegmentSec ?? p.statusSegmentSec;
  final split = segmentSec != null && o.splitForStatus && s.durationMs > segmentSec * 1000 + 500;
  final srcMatches = !isCustom &&
      !o.forceReencode &&
      !split &&
      s.videoCodec == codec &&
      !s.isHdr &&
      s.bitDepth == 8 &&
      !s.isVfr &&
      !fpsChanged &&
      !g.upscaled &&
      g.w == s.displayWidth &&
      g.h == s.displayHeight &&
      srcRate >= floor * 0.75 &&
      srcRate <= range.max * codecScale * 1.6 &&
      audioMode != 'transcode';
  if (srcMatches) {
    notes
      ..clear()
      ..add('This video is already an optimal upload master (${codecLabel(codec)}, '
          '${s.displayWidth}×${s.displayHeight}, ${formatFps(srcFps)}, ${formatBitrate(srcRate)}).')
      ..add('Re-encoding would only lose quality, so HD CLEAN re-packages it into a fast-start MP4 '
          'without touching the picture. Turn on "Force re-encode" to override.');
  } else {
    notes.add('${codecLabel(codec)} ${codec == 'h264' ? 'High' : 'Main'} profile, ${formatBitrate(videoBitrate)}, '
        '1-second keyframes, progressive, BT.709, fast-start MP4.');
  }

  final plan = EncodePlan(
    width: g.w,
    height: g.h,
    contentWidth: g.cw,
    contentHeight: g.ch,
    frameMode: g.mode,
    fps: double.parse(fps.toStringAsFixed(3)),
    convertToCfr: cfr,
    videoCodec: codec,
    videoBitrate: videoBitrate,
    keyframeIntervalSec: 1.0,
    toneMapHdr: toneMap,
    audioMode: srcMatches ? (s.hasAudio ? 'copy' : 'none') : audioMode,
    audioBitrate: audioTarget,
    audioSampleRate: 48000,
    remuxOnly: srcMatches,
    upscaled: g.upscaled,
  );

  // ---------- Splitting for Status ----------
  final parts = <EncodePlan>[];
  if (split) {
    final n = (s.durationMs / (segmentSec * 1000)).ceil();
    final len = (s.durationMs / n).ceil();
    for (var k = 0; k < n; k++) {
      parts.add(plan.copyWith(startMs: k * len, endMs: math.min(s.durationMs, (k + 1) * len)));
    }
    notes.add('Longer than $segmentSec s: split into $n parts of about ${(len / 1000).round()} s for Status.');
  } else {
    parts.add(plan);
  }

  final seconds = s.durationMs / 1000;
  final estimated = srcMatches
      ? s.sizeBytes
      : ((videoBitrate + (audioMode == 'none' ? 0 : audioTarget)) * seconds / 8 * 1.012).round() +
          40000 * parts.length;

  return PlanResult(
    plan: plan,
    parts: parts,
    estimatedBytes: estimated,
    decisions: notes,
    alreadyOptimized: srcMatches,
  );
}
