// Upload Doctor: finds the concrete reasons a video tends to "break up"
// (blocky, blurry, washed out, stuttering) after a social platform re-encodes
// it, and states what HD CLEAN does about each one. Pure rules over measured
// properties — no invented scores.

import 'models.dart';
import 'presets.dart';

enum Severity { ok, info, warning, critical }

class Finding {
  const Finding(this.severity, this.title, this.detail, {this.fix});
  final Severity severity;
  final String title;
  final String detail;

  /// What HD CLEAN does about it (null when the user must act, or nothing to do).
  final String? fix;
}

class SourceAssessment {
  const SourceAssessment(this.grade, this.summary);

  /// Excellent, Good, Fair or Limited.
  final String grade;
  final String summary;
}

SourceAssessment assessSource(VideoInfo s) {
  final bpp = s.h264EquivalentBpp;
  final res = s.resolutionLabel;
  if (s.shortSide < 700) {
    return SourceAssessment('Limited',
        '$res source. It can be cleaned up for upload, but sharpness is limited by the original resolution.');
  }
  if (bpp > 0 && bpp < 0.06) {
    return SourceAssessment('Fair',
        '$res, but already heavily compressed (${formatBitrate(s.effectiveVideoBitrate)}). Likely downloaded or '
        'forwarded from an app. HD CLEAN will protect what is left; lost detail cannot be restored.');
  }
  if (bpp > 0 && bpp < 0.12) {
    return SourceAssessment('Good',
        '$res with moderate compression. A clean, correctly formatted upload master will keep it crisp.');
  }
  return SourceAssessment('Excellent',
      '$res with plenty of detail (${formatBitrate(s.effectiveVideoBitrate)}). Ideal for an HD upload.');
}

List<Finding> diagnose(VideoInfo s, Preset p) {
  final f = <Finding>[];
  final fps = s.fps;

  if (s.isHdr) {
    f.add(Finding(Severity.critical, '${s.hdr} HDR video',
        'Most platforms convert HDR to SDR with a basic conversion. Result: washed-out, grey or blown-out colours and blocky skies.',
        fix: 'Tone-mapped on your device to SDR BT.709 with correct colour tags.'));
  } else if (s.bitDepth > 8) {
    f.add(Finding(Severity.warning, '${s.bitDepth}-bit colour',
        'Platforms deliver 8-bit video. Letting them convert can cause banding in gradients.',
        fix: 'Converted to 8-bit 4:2:0 BT.709.'));
  }

  if (s.isVfr) {
    final range = (s.minFps != null && s.maxFps != null)
        ? ' (${s.minFps!.toStringAsFixed(0)}–${s.maxFps!.toStringAsFixed(0)} fps)'
        : '';
    f.add(Finding(Severity.warning, 'Variable frame rate$range',
        'Common with phone cameras and screen recordings. After re-encoding it can cause stutter, frozen frames or audio drifting out of sync.',
        fix: 'Converted to constant frame rate.'));
  }

  if (fps > p.maxFps + 0.5) {
    f.add(Finding(Severity.info, '${fps.round()} FPS is above ${p.platform}\'s ${p.maxFps.round()} FPS',
        'The platform would drop frames itself, often unevenly.',
        fix: p.platform == 'TikTok'
            ? 'Reduced evenly to ${p.maxFps.round()} FPS, or keep up to 120 FPS with "Keep high frame rate" and TikTok HD Direct.'
            : 'Reduced with an even cadence (no judder).'));
  }

  if (s.shortSide > p.shortEdge * 1.05) {
    f.add(Finding(Severity.info, '${s.resolutionLabel} is above the ${p.platform} upload size',
        'The platform will resize it with a fast server-side scaler and then compress it — two lossy steps.',
        fix: 'Resized once on your device with high-quality filtering to the exact upload size.'));
  } else if (s.shortSide < 1000) {
    f.add(const Finding(Severity.warning, 'Below 1080p',
        'Platforms often place sub-1080p uploads in a lower-bitrate quality tier, which makes them look softer.',
        fix: 'Native resolution is kept. Optional: export at 1080p to enter the HD tier (does not add real detail).'));
  }

  final bpp = s.h264EquivalentBpp;
  if (bpp > 0 && bpp < 0.06) {
    f.add(Finding(Severity.warning, 'Source already heavily compressed',
        'At ${formatBitrate(s.effectiveVideoBitrate)} this file has probably been through WhatsApp, Telegram or a download. Each extra compression step makes blocks more visible.',
        fix: 'Encoded at a high, clean bitrate so the platform\'s compression starts from the best possible copy. '
            'Tip: use the original camera file whenever you can.'));
  }

  if (s.videoCodec != 'h264') {
    f.add(Finding(Severity.info, '${codecLabel(s.videoCodec)} source',
        'H.264 High Profile is the most widely compatible upload format; some apps handle other codecs less consistently.',
        fix: p.allowHevc ? 'H.264 by default (HEVC available for 4K).' : 'Encoded to H.264 High Profile.'));
  }

  final aspect916 = 9 / 16;
  final a = s.isPortrait ? s.aspect : 1 / s.aspect;
  final diff = (a - aspect916).abs() / aspect916;
  if (!s.isPortrait) {
    f.add(const Finding(Severity.info, 'Landscape video',
        'On TikTok, Reels and Status it will appear with bars. Choose "Fit 9:16" to control the bars yourself or "Fill 9:16" to crop to full screen.',
        fix: 'Orientation is preserved by default — never stretched.'));
  } else if (diff > 0.005) {
    f.add(Finding(Severity.info, 'Not exactly 9:16 (${s.displayWidth}×${s.displayHeight})',
        'The platform pads or crops non-standard sizes and resamples the picture, softening it.',
        fix: diff < 0.02 ? 'Matched exactly to 9:16 with a tiny edge trim.' : 'Choose Keep, Fit or Fill below.'));
  }
  if (s.displayWidth.isOdd || s.displayHeight.isOdd) {
    f.add(const Finding(Severity.info, 'Odd pixel dimensions',
        '4:2:0 video needs even dimensions; platforms fix this by resampling.',
        fix: 'Output uses even dimensions.'));
  }

  if (s.rotation != 0) {
    f.add(Finding(Severity.info, 'Rotation flag (${s.rotation}°)',
        'The file relies on a rotation tag. Some editors and apps ignore it.',
        fix: 'Rotation is applied to the pixels.'));
  }

  final cap = (fps > 31 ? p.rate60.max : p.rate30.max) * 2.2;
  if (s.effectiveVideoBitrate > cap) {
    f.add(Finding(Severity.info, 'Very high bitrate (${formatBitrate(s.effectiveVideoBitrate)})',
        'Bigger than the platform can use: slower uploads and a higher chance of the upload being re-processed at low priority.',
        fix: 'Reduced to the platform\'s useful maximum.'));
  }

  if (s.hasAudio) {
    if (s.audioCodec != 'aac') {
      f.add(Finding(Severity.info, '${codecLabel(s.audioCodec ?? 'other')} audio',
          'AAC is the audio format every platform accepts without conversion.',
          fix: 'Converted to AAC-LC 48 kHz.'));
    } else if (s.audioSampleRate != null && s.audioSampleRate != 48000) {
      f.add(Finding(Severity.info, 'Audio at ${(s.audioSampleRate! / 1000).toStringAsFixed(1)} kHz',
          'Video platforms work at 48 kHz and resample other rates.',
          fix: 'Resampled once to 48 kHz.'));
    } else if ((s.audioBitrate ?? 999999) < 96000) {
      f.add(const Finding(Severity.info, 'Low audio bitrate',
          'The audio is already compressed; it will be kept as clean as possible.'));
    }
  } else {
    f.add(const Finding(Severity.info, 'No audio track', 'The video has no sound.'));
  }

  if (p.statusSegmentSec != null && s.durationMs > p.statusSegmentSec! * 1000 + 500) {
    f.add(Finding(Severity.warning, 'Longer than ${p.statusSegmentSec} s',
        'WhatsApp Status trims or splits long videos itself, with an extra compression pass.',
        fix: 'Split into equal parts ready to post one after another.'));
  }

  f.add(const Finding(Severity.ok, 'Fast-start MP4',
      'The index is placed at the start of the file so uploads are processed immediately.',
      fix: 'Always applied.'));

  f.sort((a, b) => b.severity.index.compareTo(a.severity.index));
  return f;
}

/// Platform-side settings and habits that matter as much as the file itself.
List<String> uploadTips(Preset p) => switch (p.platform) {
      'TikTok' => const [
          'Best quality: use "TikTok HD Direct". The TikTok app re-compresses videos on your phone before uploading; the web uploader sends the file itself.',
          'Turn on "Allow high-quality uploads" / "Upload HD" in TikTok: Settings and privacy → Data saver / Upload quality (name varies by version).',
          'Upload on Wi-Fi. On slow or metered connections TikTok may compress harder.',
          'Avoid adding TikTok filters or effects that re-render the whole video; add text and sounds sparingly.',
          'Post the HD CLEAN file directly. Do not re-save it from TikTok drafts or forward it through a chat app first.',
        ],
      'Instagram' => const [
          'Turn on Settings → Data usage and media quality → "Upload at highest quality".',
          'Turn off "Data saver" while uploading.',
          'Upload on Wi-Fi and keep Instagram open until the upload completes.',
          'Avoid Instagram filters that re-render the full video.',
        ],
      'WhatsApp' => const [
          'Tap the "HD" button before sending to a chat; for Status, choose HD quality in Settings → Storage and data → Media upload quality.',
          'Post the parts in order so viewers see them as one sequence.',
          'WhatsApp may still reduce the resolution of Status videos; this file gives it the cleanest possible starting point.',
        ],
      _ => const [
          'Upload on Wi-Fi with the app\'s highest upload-quality setting enabled.',
          'Share the exported file directly — every extra app or chat in between adds another compression pass.',
        ],
    };
