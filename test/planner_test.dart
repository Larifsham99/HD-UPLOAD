import 'package:flutter_test/flutter_test.dart';
import 'package:hd_clean/engine/models.dart';
import 'package:hd_clean/engine/planner.dart';
import 'package:hd_clean/engine/presets.dart';
import 'package:hd_clean/engine/tiktok_sim.dart';
import 'package:hd_clean/engine/upload_doctor.dart';

VideoInfo src({
  int w = 1080,
  int h = 1920,
  int rotation = 0,
  double fps = 30,
  int bitrate = 16000000,
  String codec = 'h264',
  String? hdr,
  int bitDepth = 8,
  bool vfr = false,
  int durationMs = 20000,
  bool audio = true,
  String audioCodec = 'aac',
  int sampleRate = 48000,
  int audioBitrate = 256000,
  int channels = 2,
}) =>
    VideoInfo(
      uri: 'test.mp4',
      name: 'test.mp4',
      sizeBytes: ((bitrate + (audio ? audioBitrate : 0)) * durationMs / 8000).round(),
      width: w,
      height: h,
      rotation: rotation,
      durationMs: durationMs,
      fps: fps,
      videoBitrate: bitrate,
      videoCodec: codec,
      bitDepth: bitDepth,
      hdr: hdr,
      isVfr: vfr,
      hasAudio: audio,
      audioCodec: audio ? audioCodec : null,
      audioSampleRate: audio ? sampleRate : null,
      audioChannels: audio ? channels : null,
      audioBitrate: audio ? audioBitrate : null,
    );

PlanResult plan(VideoInfo s, [Preset p = Preset.tiktokHd, PlanOptions Function(PlanOptions)? tweak]) {
  var o = PlanOptions(preset: p);
  if (tweak != null) o = tweak(o);
  return planEncode(s, o);
}

void main() {
  group('resolution', () {
    test('4K portrait iPhone HDR → 1080×1920, tone-mapped, downscaled', () {
      final r = plan(src(w: 3840, h: 2160, rotation: 90, codec: 'hevc', hdr: 'HLG', bitDepth: 10, bitrate: 45000000, fps: 30));
      expect(r.plan.width, 1080);
      expect(r.plan.height, 1920);
      expect(r.plan.toneMapHdr, isTrue);
      expect(r.alreadyOptimized, isFalse);
      expect(r.plan.videoCodec, 'h264');
    });

    test('never upscales 720p by default', () {
      final r = plan(src(w: 720, h: 1280, bitrate: 5000000));
      expect((r.plan.width, r.plan.height), (720, 1280));
      expect(r.plan.upscaled, isFalse);
    });

    test('720p → 1080p only when the upload tier option is on, and is flagged', () {
      final r = plan(src(w: 720, h: 1280, bitrate: 5000000), Preset.tiktokHd, (o) => o.copyWith(allowUpscaleTo1080: true));
      expect((r.plan.width, r.plan.height), (1080, 1920));
      expect(r.plan.upscaled, isTrue);
      expect(r.decisions.join(' '), contains('does not add detail'));
    });

    test('landscape keeps orientation and aspect (no stretching)', () {
      final r = plan(src(w: 3840, h: 2160, bitrate: 50000000));
      expect((r.plan.width, r.plan.height), (1920, 1080));
    });

    test('landscape Fit 9:16 → 1080×1920 canvas with full picture inside', () {
      final r = plan(src(w: 1920, h: 1080), Preset.tiktokHd, (o) => o.copyWith(frameMode: FrameMode.fit));
      expect((r.plan.width, r.plan.height), (1080, 1920));
      expect((r.plan.contentWidth, r.plan.contentHeight), (1080, 608));
      expect(r.plan.frameMode, FrameMode.fit);
    });

    test('landscape Fill 9:16 → 1080×1920 crop', () {
      final r = plan(src(w: 3840, h: 2160, bitrate: 50000000), Preset.tiktokHd, (o) => o.copyWith(frameMode: FrameMode.fill));
      expect((r.plan.width, r.plan.height), (1080, 1920));
      expect(r.plan.contentHeight, 1920);
      expect(r.plan.contentWidth, greaterThan(1080));
    });

    test('small landscape source in Fit mode shrinks the canvas instead of upscaling', () {
      final r = plan(src(w: 960, h: 540, bitrate: 4000000), Preset.tiktokHd, (o) => o.copyWith(frameMode: FrameMode.fit));
      expect(r.plan.contentWidth, 960);
      expect(r.plan.width, 960);
      expect(r.plan.height, 1706);
      expect(r.plan.upscaled, isFalse);
    });

    test('near-9:16 source (1080×1916) is matched exactly with a tiny trim', () {
      final r = plan(src(w: 1080, h: 1916));
      expect((r.plan.width, r.plan.height), (1080, 1920));
      expect(r.plan.frameMode, FrameMode.fill);
    });

    test('odd source dimensions produce even output', () {
      final r = plan(src(w: 887, h: 1921, bitrate: 9000000));
      expect(r.plan.width.isEven && r.plan.height.isEven, isTrue);
    });

    test('4K preset refuses non-4K source', () {
      expect(() => plan(src(), Preset.tiktok4k), throwsA(isA<PlannerException>()));
    });

    test('4K preset with 4K source gives 2160×3840 and allows HEVC', () {
      final r = plan(src(w: 2160, h: 3840, bitrate: 60000000, codec: 'hevc'), Preset.tiktok4k, (o) => o.copyWith(codec: 'hevc'));
      expect((r.plan.width, r.plan.height), (2160, 3840));
      expect(r.plan.videoCodec, 'hevc');
    });
  });

  group('frame rate', () {
    test('preserves 60 fps for TikTok', () => expect(plan(src(fps: 60, bitrate: 25000000)).plan.fps, 60));
    test('preserves 29.97', () => expect(plan(src(fps: 29.97)).plan.fps, 29.97));
    test('120 kept with highFrameRate on TikTok, bitrate raised', () {
      final r = plan(src(fps: 120, bitrate: 50000000), Preset.tiktokHd, (o) => o.copyWith(highFrameRate: true, quality: QualityMode.maximum));
      expect(r.plan.fps, 120);
      expect(r.plan.videoBitrate, greaterThan(20000000));
    });
    test('highFrameRate ignored for WhatsApp', () {
      expect(plan(src(fps: 120, bitrate: 50000000), Preset.whatsapp, (o) => o.copyWith(highFrameRate: true)).plan.fps, 30);
    });
    test('120 → 60 (even cadence)', () => expect(plan(src(fps: 120, bitrate: 40000000)).plan.fps, 60));
    test('WhatsApp 60 → 30', () => expect(plan(src(fps: 60), Preset.whatsapp).plan.fps, 30));
    test('WhatsApp 50 → 25 (not 30, avoids judder)', () => expect(plan(src(fps: 50), Preset.whatsapp).plan.fps, 25));
    test('VFR is converted to CFR at the snapped average', () {
      final r = plan(src(fps: 29.6, vfr: true));
      expect(r.plan.fps, 29.97);
      expect(r.plan.convertToCfr, isTrue);
    });
    test('custom FPS above source is capped', () {
      final r = plan(src(fps: 30), Preset.custom, (o) => o.copyWith(customFps: () => 60));
      expect(r.plan.fps, 30);
    });
  });

  group('bitrate', () {
    test('TikTok HD 1080p30 stays within 12–16 Mbps for a good source', () {
      for (final q in [QualityMode.balanced, QualityMode.maximum]) {
        final b = plan(src(bitrate: 30000000), Preset.tiktokHd, (o) => o.copyWith(quality: q)).plan.videoBitrate;
        expect(b, inInclusiveRange(12000000, 16000000), reason: q.name);
      }
    });

    test('TikTok HD 1080p60 maximum = 20 Mbps', () {
      expect(plan(src(fps: 60, bitrate: 40000000), Preset.tiktokHd, (o) => o.copyWith(quality: QualityMode.maximum)).plan.videoBitrate, 20000000);
    });

    test('modes are ordered: smaller < balanced ≤ maximum', () {
      int b(QualityMode q) => plan(src(bitrate: 25000000), Preset.tiktokHd, (o) => o.copyWith(quality: q)).plan.videoBitrate;
      expect(b(QualityMode.smaller), lessThan(b(QualityMode.balanced)));
      expect(b(QualityMode.balanced), lessThanOrEqualTo(b(QualityMode.maximum)));
    });

    test('heavily compressed source is not inflated beyond the preset floor', () {
      final r = plan(src(bitrate: 2500000), Preset.tiktokHd, (o) => o.copyWith(quality: QualityMode.maximum));
      expect(r.plan.videoBitrate, 12000000);
    });

    test('HEVC output uses less bitrate than H.264', () {
      final s = src(w: 2160, h: 3840, bitrate: 80000000);
      final h264 = plan(s, Preset.tiktok4k).plan.videoBitrate;
      final hevc = plan(s, Preset.tiktok4k, (o) => o.copyWith(codec: 'hevc')).plan.videoBitrate;
      expect(hevc, lessThan(h264));
    });

    test('estimate matches bitrate × duration', () {
      final r = plan(src(durationMs: 60000, bitrate: 30000000));
      final expected = (r.plan.videoBitrate + r.plan.audioBitrate) * 60 / 8;
      expect(r.estimatedBytes, closeTo(expected, expected * 0.03));
    });
  });

  group('no unnecessary re-encode', () {
    test('already optimal TikTok master → remux only', () {
      final r = plan(src(bitrate: 14000000));
      expect(r.alreadyOptimized, isTrue);
      expect(r.plan.remuxOnly, isTrue);
      expect(r.estimatedBytes, src(bitrate: 14000000).sizeBytes);
    });

    test('force re-encode overrides', () {
      expect(plan(src(bitrate: 14000000), Preset.tiktokHd, (o) => o.copyWith(forceReencode: true)).alreadyOptimized, isFalse);
    });

    test('HEVC / VFR / HDR / 44.1 kHz sources are not passed through', () {
      expect(plan(src(codec: 'hevc', bitrate: 9000000)).alreadyOptimized, isFalse);
      expect(plan(src(vfr: true, bitrate: 14000000)).alreadyOptimized, isFalse);
      expect(plan(src(hdr: 'HLG', bitDepth: 10, bitrate: 14000000)).alreadyOptimized, isFalse);
      expect(plan(src(sampleRate: 44100, bitrate: 14000000)).alreadyOptimized, isFalse);
    });
  });

  group('audio', () {
    test('AAC 48k 256k is copied', () => expect(plan(src(codec: 'hevc')).plan.audioMode, 'copy'));
    test('AAC 44.1k is resampled to 48k', () {
      final p = plan(src(codec: 'hevc', sampleRate: 44100)).plan;
      expect(p.audioMode, 'transcode');
      expect(p.audioSampleRate, 48000);
      expect(p.audioBitrate, 256000);
    });
    test('AAC 48k at 160k (typical phone) is copied, not re-encoded', () {
      expect(plan(src(codec: 'hevc', audioBitrate: 160000)).plan.audioMode, 'copy');
    });
    test('5.1 AAC is downmixed (transcoded)', () => expect(plan(src(codec: 'hevc', channels: 6)).plan.audioMode, 'transcode'));
    test('Opus → AAC', () => expect(plan(src(codec: 'vp9', audioCodec: 'opus')).plan.audioMode, 'transcode'));
    test('no audio → none', () => expect(plan(src(codec: 'hevc', audio: false)).plan.audioMode, 'none'));
  });

  group('WhatsApp Status split', () {
    test('150 s video → 3 equal parts ≤ 60 s', () {
      final r = plan(src(durationMs: 150000), Preset.whatsapp);
      expect(r.parts.length, 3);
      expect(r.parts.first.startMs, 0);
      expect(r.parts.last.endMs, 150000);
      for (final p in r.parts) {
        expect(p.endMs! - p.startMs!, lessThanOrEqualTo(60000));
      }
      expect(r.alreadyOptimized, isFalse);
    });
    test('split can be disabled', () {
      expect(plan(src(durationMs: 150000), Preset.whatsapp, (o) => o.copyWith(splitForStatus: false)).parts.length, 1);
    });
    test('custom 30 s parts', () {
      expect(plan(src(durationMs: 95000), Preset.whatsapp, (o) => o.copyWith(statusSegmentSec: 30)).parts.length, 4);
    });
  });

  group('upload doctor', () {
    test('HDR is critical, VFR warned, fast-start always reported', () {
      final f = diagnose(src(hdr: 'HLG', bitDepth: 10, vfr: true), Preset.tiktokHd);
      expect(f.first.severity, Severity.critical);
      expect(f.any((x) => x.title.contains('Variable frame rate')), isTrue);
      expect(f.any((x) => x.title == 'Fast-start MP4'), isTrue);
    });
    test('heavily compressed source warned', () {
      expect(diagnose(src(bitrate: 2000000), Preset.tiktokHd).any((x) => x.title.contains('heavily compressed')), isTrue);
      expect(assessSource(src(bitrate: 2000000)).grade, 'Fair');
      expect(assessSource(src(bitrate: 20000000)).grade, 'Excellent');
    });
    test('720p warned as below 1080p', () {
      expect(diagnose(src(w: 720, h: 1280, bitrate: 5000000), Preset.tiktokHd).any((x) => x.title == 'Below 1080p'), isTrue);
    });
    test('long video on WhatsApp warns about Status length', () {
      expect(diagnose(src(durationMs: 120000), Preset.whatsapp).any((x) => x.title.contains('Longer than')), isTrue);
    });
  });

  group('TikTok Survival Mode', () {
    test('adds denoise + shadow lift, forces re-encode, caps 60 → 30 FPS', () {
      final r = plan(src(fps: 60, bitrate: 16000000), Preset.tiktokHd, (o) => o.copyWith(survival: SurvivalLevel.medium));
      expect(r.plan.denoise, closeTo(0.6, 1e-9));
      expect(r.plan.shadowLift, greaterThan(0));
      expect(r.plan.fps, 30);
      expect(r.alreadyOptimized, isFalse);
      expect(r.plan.toMap()['denoise'], 0.6);
    });
    test('survival can keep source FPS', () {
      expect(plan(src(fps: 60, bitrate: 20000000), Preset.tiktokHd, (o) => o.copyWith(survival: SurvivalLevel.gentle, survivalFps: () => null)).plan.fps, 60);
    });
    test('survival is ignored for WhatsApp', () {
      expect(plan(src(), Preset.whatsapp, (o) => o.copyWith(survival: SurvivalLevel.strong)).plan.denoise, 0);
    });
    test('simulation plan: short middle clip, low bitrate, fewer bits per frame at 60 FPS', () {
      final p = tiktokSimulationPlan(width: 1080, height: 1920, fps: 30, durationMs: 30000);
      expect(p.endMs! - p.startMs!, 6000);
      expect(p.startMs, 12000);
      expect(p.videoBitrate, 2500000);
      final b60 = tiktokDeliveryBitrate(1080, 1920, 60);
      expect(b60, greaterThan(2500000));
      expect(b60 / 60, lessThan(2500000 / 30));
    });
  });

  test('snapFps', () {
    expect(snapFps(29.6), 29.97);
    expect(snapFps(59.8), 59.94);
    expect(snapFps(24.0), 24);
    expect(snapFps(12.0), 12);
  });
}
