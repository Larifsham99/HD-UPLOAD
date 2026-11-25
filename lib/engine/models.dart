// Core data models shared by the planner, the native bridge and the UI.
//
// Everything in this file is plain Dart so it can be unit-tested without a
// device. Values that come from the native side arrive as Map<String, Object?>.

import 'dart:math' as math;

/// Information about a source video, produced by the native probe
/// (Android: MediaExtractor + MediaMetadataRetriever, iOS: AVFoundation).
class VideoInfo {
  const VideoInfo({
    required this.uri,
    required this.name,
    required this.sizeBytes,
    required this.width,
    required this.height,
    required this.rotation,
    required this.durationMs,
    required this.fps,
    required this.videoBitrate,
    required this.videoCodec,
    this.videoProfile,
    this.bitDepth = 8,
    this.hdr,
    this.isVfr = false,
    this.minFps,
    this.maxFps,
    this.hasAudio = true,
    this.audioCodec,
    this.audioSampleRate,
    this.audioChannels,
    this.audioBitrate,
  });

  /// Platform reference to the file (content:// URI on Android, file path on iOS).
  final String uri;
  final String name;
  final int sizeBytes;

  /// Encoded (stored) dimensions, before applying [rotation].
  final int width;
  final int height;

  /// Rotation metadata in degrees (0, 90, 180, 270).
  final int rotation;
  final int durationMs;

  /// Average frame rate.
  final double fps;

  /// Video stream bitrate in bits per second (0 when unknown).
  final int videoBitrate;

  /// Normalised codec id: h264, hevc, vp9, av1, prores, mpeg4, other.
  final String videoCodec;
  final String? videoProfile;
  final int bitDepth;

  /// null for SDR, otherwise "HLG", "HDR10", "HDR10+" or "Dolby Vision".
  final String? hdr;
  final bool isVfr;
  final double? minFps;
  final double? maxFps;

  final bool hasAudio;

  /// Normalised audio codec id: aac, opus, mp3, ac3, eac3, pcm, amr, other.
  final String? audioCodec;
  final int? audioSampleRate;
  final int? audioChannels;
  final int? audioBitrate;

  bool get isHdr => hdr != null;
  bool get isRotated => rotation == 90 || rotation == 270;

  /// Width/height as the viewer sees them (rotation applied).
  int get displayWidth => isRotated ? height : width;
  int get displayHeight => isRotated ? width : height;
  bool get isPortrait => displayHeight >= displayWidth;
  int get shortSide => math.min(width, height);
  int get longSide => math.max(width, height);
  double get aspect => displayWidth / displayHeight;
  int get pixels => width * height;

  /// Best estimate of the video bitrate. Falls back to the container average
  /// when the stream bitrate was not reported.
  int get effectiveVideoBitrate {
    if (videoBitrate > 0) return videoBitrate;
    if (durationMs <= 0) return 0;
    final total = sizeBytes * 8 * 1000 ~/ durationMs;
    return math.max(0, total - (audioBitrate ?? (hasAudio ? 128000 : 0)));
  }

  /// Bits per pixel per frame, normalised to H.264 efficiency.
  /// This is the single most useful number to tell how much compression
  /// a source has already been through.
  double get h264EquivalentBpp {
    final rate = effectiveVideoBitrate;
    if (rate <= 0 || pixels <= 0 || fps <= 0) return 0;
    return rate * codecEfficiency(videoCodec) / (pixels * fps);
  }

  String get resolutionLabel {
    final s = shortSide;
    if (s >= 2100) return '4K';
    if (s >= 1400) return '1440p';
    if (s >= 1000) return '1080p';
    if (s >= 700) return '720p';
    if (s >= 470) return '480p';
    return '${s}p';
  }

  factory VideoInfo.fromMap(Map<Object?, Object?> m) {
    int i(String k, [int d = 0]) => (m[k] as num?)?.toInt() ?? d;
    double? dn(String k) => (m[k] as num?)?.toDouble();
    return VideoInfo(
      uri: m['uri'] as String,
      name: (m['name'] as String?) ?? 'video.mp4',
      sizeBytes: i('sizeBytes'),
      width: i('width'),
      height: i('height'),
      rotation: ((i('rotation') % 360) + 360) % 360,
      durationMs: i('durationMs'),
      fps: dn('fps') ?? 30,
      videoBitrate: i('videoBitrate'),
      videoCodec: normaliseVideoCodec(m['videoCodec'] as String?),
      videoProfile: m['videoProfile'] as String?,
      bitDepth: i('bitDepth', 8),
      hdr: m['hdr'] as String?,
      isVfr: (m['isVfr'] as bool?) ?? false,
      minFps: dn('minFps'),
      maxFps: dn('maxFps'),
      hasAudio: (m['hasAudio'] as bool?) ?? false,
      audioCodec: m['audioCodec'] == null
          ? null
          : normaliseAudioCodec(m['audioCodec'] as String?),
      audioSampleRate: (m['audioSampleRate'] as num?)?.toInt(),
      audioChannels: (m['audioChannels'] as num?)?.toInt(),
      audioBitrate: (m['audioBitrate'] as num?)?.toInt(),
    );
  }

  Map<String, Object?> toMap() => {
        'uri': uri,
        'name': name,
        'sizeBytes': sizeBytes,
        'width': width,
        'height': height,
        'rotation': rotation,
        'durationMs': durationMs,
        'fps': fps,
        'videoBitrate': videoBitrate,
        'videoCodec': videoCodec,
        'videoProfile': videoProfile,
        'bitDepth': bitDepth,
        'hdr': hdr,
        'isVfr': isVfr,
        'minFps': minFps,
        'maxFps': maxFps,
        'hasAudio': hasAudio,
        'audioCodec': audioCodec,
        'audioSampleRate': audioSampleRate,
        'audioChannels': audioChannels,
        'audioBitrate': audioBitrate,
      };
}

/// Relative compression efficiency compared to H.264 (higher = needs fewer bits).
double codecEfficiency(String codec) => switch (codec) {
      'hevc' => 1.6,
      'av1' => 1.9,
      'vp9' => 1.5,
      'mpeg4' => 0.7,
      'prores' => 1.0,
      _ => 1.0,
    };

String normaliseVideoCodec(String? raw) {
  final s = (raw ?? '').toLowerCase();
  if (s.contains('avc') || s.contains('264')) return 'h264';
  if (s.contains('hevc') || s.contains('265') || s.contains('hvc') || s.contains('hev1')) {
    return 'hevc';
  }
  if (s.contains('dolby') || s.contains('dvh')) return 'hevc';
  if (s.contains('vp9') || s.contains('vp09')) return 'vp9';
  if (s.contains('av01') || s.contains('av1')) return 'av1';
  if (s.contains('prores') || s.contains('apc')) return 'prores';
  if (s.contains('mp4v') || s.contains('mpeg4')) return 'mpeg4';
  return s.isEmpty ? 'other' : s;
}

String normaliseAudioCodec(String? raw) {
  final s = (raw ?? '').toLowerCase();
  if (s.contains('aac') || s.contains('mp4a')) return 'aac';
  if (s.contains('opus')) return 'opus';
  if (s.contains('mpeg') || s.contains('mp3')) return 'mp3';
  if (s.contains('eac3') || s.contains('ec-3')) return 'eac3';
  if (s.contains('ac3') || s.contains('ac-3')) return 'ac3';
  if (s.contains('raw') || s.contains('pcm') || s.contains('lpcm')) return 'pcm';
  if (s.contains('amr') || s.contains('3gpp')) return 'amr';
  return s.isEmpty ? 'other' : s;
}

String codecLabel(String codec) => switch (codec) {
      'h264' => 'H.264 / AVC',
      'hevc' => 'HEVC / H.265',
      'vp9' => 'VP9',
      'av1' => 'AV1',
      'prores' => 'ProRes',
      'mpeg4' => 'MPEG-4',
      'aac' => 'AAC',
      'opus' => 'Opus',
      'mp3' => 'MP3',
      'pcm' => 'PCM',
      _ => codec.toUpperCase(),
    };

/// How to handle a source whose aspect ratio is not the target's.
enum FrameMode {
  /// Keep the source aspect ratio, scale to fit the platform box. No bars, no crop.
  keep,

  /// 9:16 canvas, whole picture visible, black bars where needed.
  fit,

  /// 9:16 canvas, picture fills the frame, edges cropped.
  fill,
}

enum QualityMode { maximum, balanced, smaller }

/// TikTok Survival Mode: prepares the picture so it survives TikTok's own
/// low-bitrate re-encode (removes sensor noise that would eat its bitrate,
/// lifts deep shadows where encoders cause blocking first).
enum SurvivalLevel { off, gentle, medium, strong }

extension SurvivalLevelValues on SurvivalLevel {
  String get label => switch (this) {
        SurvivalLevel.off => 'Off',
        SurvivalLevel.gentle => 'Gentle',
        SurvivalLevel.medium => 'Medium',
        SurvivalLevel.strong => 'Strong',
      };

  /// Edge-preserving noise reduction strength, 0–1.
  double get denoise => switch (this) {
        SurvivalLevel.off => 0,
        SurvivalLevel.gentle => 0.35,
        SurvivalLevel.medium => 0.6,
        SurvivalLevel.strong => 0.9,
      };

  /// Shadow lift strength, 0–1.
  double get shadowLift => switch (this) {
        SurvivalLevel.off => 0,
        SurvivalLevel.gentle => 0.3,
        SurvivalLevel.medium => 0.5,
        SurvivalLevel.strong => 0.7,
      };
}

extension QualityModeLabel on QualityMode {
  String get label => switch (this) {
        QualityMode.maximum => 'Maximum Quality',
        QualityMode.balanced => 'Balanced HD',
        QualityMode.smaller => 'Smaller File',
      };
}

/// Everything the native engine needs to produce one output file.
class EncodePlan {
  const EncodePlan({
    required this.width,
    required this.height,
    required this.contentWidth,
    required this.contentHeight,
    required this.frameMode,
    required this.fps,
    required this.convertToCfr,
    required this.videoCodec,
    required this.videoBitrate,
    required this.keyframeIntervalSec,
    required this.toneMapHdr,
    required this.audioMode,
    required this.audioBitrate,
    required this.audioSampleRate,
    required this.remuxOnly,
    required this.upscaled,
    this.startMs,
    this.endMs,
    this.denoise = 0,
    this.shadowLift = 0,
  });

  /// Output frame size (always even).
  final int width;
  final int height;

  /// Size of the actual picture inside the frame (differs from width/height
  /// only for [FrameMode.fit]; larger for [FrameMode.fill] before cropping).
  final int contentWidth;
  final int contentHeight;
  final FrameMode frameMode;
  final double fps;
  final bool convertToCfr;

  /// h264 or hevc
  final String videoCodec;
  final int videoBitrate;
  final double keyframeIntervalSec;
  final bool toneMapHdr;

  /// 'transcode', 'copy' or 'none'
  final String audioMode;
  final int audioBitrate;
  final int audioSampleRate;

  /// True when the source is already optimal: only re-wrap into a fast-start
  /// MP4 without touching the compressed video (no generation loss).
  final bool remuxOnly;
  final bool upscaled;

  final int? startMs;
  final int? endMs;

  /// TikTok Survival Mode pre-conditioning (0 = off).
  final double denoise;
  final double shadowLift;

  EncodePlan copyWith({int? startMs, int? endMs}) => EncodePlan(
        width: width,
        height: height,
        contentWidth: contentWidth,
        contentHeight: contentHeight,
        frameMode: frameMode,
        fps: fps,
        convertToCfr: convertToCfr,
        videoCodec: videoCodec,
        videoBitrate: videoBitrate,
        keyframeIntervalSec: keyframeIntervalSec,
        toneMapHdr: toneMapHdr,
        audioMode: audioMode,
        audioBitrate: audioBitrate,
        audioSampleRate: audioSampleRate,
        remuxOnly: remuxOnly,
        upscaled: upscaled,
        startMs: startMs ?? this.startMs,
        endMs: endMs ?? this.endMs,
        denoise: denoise,
        shadowLift: shadowLift,
      );

  Map<String, Object?> toMap() => {
        'width': width,
        'height': height,
        'frameMode': frameMode.name,
        'fps': fps,
        'convertToCfr': convertToCfr,
        'videoCodec': videoCodec,
        'videoBitrate': videoBitrate,
        'keyframeIntervalSec': keyframeIntervalSec,
        'toneMapHdr': toneMapHdr,
        'audioMode': audioMode,
        'audioBitrate': audioBitrate,
        'audioSampleRate': audioSampleRate,
        'remuxOnly': remuxOnly,
        'startMs': startMs,
        'endMs': endMs,
        'denoise': denoise,
        'shadowLift': shadowLift,
      };
}

String formatBytes(num bytes) {
  if (bytes <= 0) return '—';
  const units = ['B', 'KB', 'MB', 'GB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(v >= 100 || u == 0 ? 0 : 1)} ${units[u]}';
}

String formatBitrate(num bps) {
  if (bps <= 0) return '—';
  if (bps >= 1000000) return '${(bps / 1000000).toStringAsFixed(1)} Mbps';
  return '${(bps / 1000).round()} kbps';
}

String formatFps(double fps) {
  final r = fps.roundToDouble();
  if ((fps - r).abs() < 0.01) return '${r.toInt()} FPS';
  return '${fps.toStringAsFixed(2)} FPS';
}

String formatDuration(int ms) {
  final s = (ms / 1000).round();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final two = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$two' : '$m:$two';
}
