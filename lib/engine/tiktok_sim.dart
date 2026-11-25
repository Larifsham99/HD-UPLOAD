// On-device approximation of TikTok's own re-encode, used by "TikTok Preview"
// to show what a video is likely to look like *after* TikTok processes it.
//
// TikTok does not publish its delivery settings. These numbers are an
// approximation of a typical 1080p delivery rendition (H.264, ~2.5 Mbps at
// 30 FPS), so the preview shows the *kind* of damage to expect (blocking in
// noise, dark areas and fast motion), not an exact replica.

import 'dart:math' as math;

import 'models.dart';

/// Approximate TikTok delivery bitrate for a given size and frame rate.
/// Higher frame rates get only slightly more bits in total, so each frame
/// gets fewer: this is why 60/120 FPS uploads often look softer on TikTok.
int tiktokDeliveryBitrate(int width, int height, double fps) {
  final pixelScale = math.pow((width * height) / (1080 * 1920), 0.75);
  final fpsScale = math.pow(math.max(fps, 24) / 30, 0.3);
  return (2500000 * pixelScale * fpsScale / 50000).round() * 50000;
}

/// A short clip (up to [clipMs]) from the middle of the video, encoded the
/// way TikTok roughly would.
EncodePlan tiktokSimulationPlan({
  required int width,
  required int height,
  required double fps,
  required int durationMs,
  FrameMode frameMode = FrameMode.keep,
  bool toneMap = false,
  int clipMs = 6000,
}) {
  final len = math.min(clipMs, durationMs);
  final start = math.max(0, (durationMs - len) ~/ 2);
  return EncodePlan(
    width: width,
    height: height,
    contentWidth: width,
    contentHeight: height,
    frameMode: frameMode,
    fps: fps,
    convertToCfr: false,
    videoCodec: 'h264',
    videoBitrate: tiktokDeliveryBitrate(width, height, fps),
    keyframeIntervalSec: 2,
    toneMapHdr: toneMap,
    audioMode: 'none',
    audioBitrate: 0,
    audioSampleRate: 48000,
    remuxOnly: false,
    upscaled: false,
    startMs: start,
    endMs: start + len,
  );
}
