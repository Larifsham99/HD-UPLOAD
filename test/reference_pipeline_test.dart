// End-to-end check of the planner, the MP4 verifier and the fast-start fixer
// on real encoded files. Uses desktop ffmpeg as a *reference* encoder that
// applies the same plan the native engines receive (the on-device engines are
// Media3/MediaCodec on Android and AVFoundation on iOS; they are compiled and
// exercised separately).
//
// Skipped automatically when ffmpeg/ffprobe are not installed.
@Tags(['ffmpeg'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hd_clean/engine/models.dart';
import 'package:hd_clean/engine/mp4_inspector.dart';
import 'package:hd_clean/engine/planner.dart';
import 'package:hd_clean/engine/presets.dart';

final hasFfmpeg = () {
  try {
    return Process.runSync('ffmpeg', ['-version']).exitCode == 0 && Process.runSync('ffprobe', ['-version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}();

Future<void> run(List<String> args) async {
  final r = await Process.run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...args]);
  if (r.exitCode != 0) throw Exception('ffmpeg failed: ${r.stderr}');
}

Future<Map<String, dynamic>> ffprobe(String path, List<String> extra) async {
  final r = await Process.run('ffprobe', ['-v', 'error', '-of', 'json', ...extra, path]);
  if (r.exitCode != 0) throw Exception('ffprobe failed: ${r.stderr}');
  return jsonDecode(r.stdout as String) as Map<String, dynamic>;
}

/// Mirrors the native probes (VideoProbe.kt / VideoProbe in AppDelegate.swift).
Future<VideoInfo> probe(String path) async {
  final j = await ffprobe(path, ['-show_streams', '-show_format']);
  final streams = (j['streams'] as List).cast<Map<String, dynamic>>();
  final v = streams.firstWhere((s) => s['codec_type'] == 'video');
  final a = streams.where((s) => s['codec_type'] == 'audio').firstOrNull;
  final fmt = j['format'] as Map<String, dynamic>;
  final durationMs = (double.parse(fmt['duration'] as String) * 1000).round();

  final pk = await ffprobe(path, ['-select_streams', 'v:0', '-show_entries', 'packet=pts_time']);
  final times = (pk['packets'] as List).map((p) => double.parse((p as Map)['pts_time'] as String)).toList()..sort();
  final deltas = <double>[for (var i = 1; i < times.length; i++) if (times[i] > times[i - 1]) times[i] - times[i - 1]];
  final sorted = [...deltas]..sort();
  final median = sorted[sorted.length ~/ 2];
  final p5 = sorted[(sorted.length * 0.05).floor()], p95 = sorted[math.min(sorted.length - 1, (sorted.length * 0.95).floor())];
  final irregular = deltas.where((d) => (d - median).abs() > median * 0.25).length;
  final vfr = irregular > deltas.length * 0.05 || (p95 - p5) > median * 0.3;

  final trc = v['color_transfer'] as String?;
  final pix = v['pix_fmt'] as String? ?? '';
  return VideoInfo(
    uri: path,
    name: path.split('/').last,
    sizeBytes: File(path).lengthSync(),
    width: v['width'] as int,
    height: v['height'] as int,
    rotation: 0,
    durationMs: durationMs,
    fps: times.length / (durationMs / 1000),
    videoBitrate: int.tryParse('${v['bit_rate']}') ?? 0,
    videoCodec: v['codec_name'] as String,
    videoProfile: v['profile'] as String?,
    bitDepth: pix.contains('10') ? 10 : 8,
    hdr: trc == 'arib-std-b67' ? 'HLG' : (trc == 'smpte2084' ? 'HDR10' : null),
    isVfr: vfr,
    minFps: 1 / p95,
    maxFps: 1 / p5,
    hasAudio: a != null,
    audioCodec: a?['codec_name'] as String?,
    audioSampleRate: a == null ? null : int.parse(a['sample_rate'] as String),
    audioChannels: a?['channels'] as int?,
    audioBitrate: a == null ? null : int.tryParse('${a['bit_rate']}'),
  );
}

/// Reference encoder: the same decisions the native engines implement.
Future<void> encode(VideoInfo s, EncodePlan p, String out) async {
  if (p.remuxOnly) {
    await run(['-i', s.uri, '-map', '0:v:0', '-map', '0:a?', '-c', 'copy', out]);
    return;
  }
  final w = p.width, h = p.height;
  final vf = <String>[
    if (p.toneMapHdr)
      'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv',
    if (p.convertToCfr) 'fps=${p.fps}',
    switch (p.frameMode) {
      FrameMode.fit => 'scale=$w:$h:force_original_aspect_ratio=decrease:flags=lanczos,pad=$w:$h:(ow-iw)/2:(oh-ih)/2:black',
      FrameMode.fill => 'scale=$w:$h:force_original_aspect_ratio=increase:flags=lanczos,crop=$w:$h',
      FrameMode.keep => 'scale=$w:$h:flags=lanczos',
    },
    'format=yuv420p',
    'setsar=1',
  ];
  final gop = math.max(1, (p.fps * p.keyframeIntervalSec).round()).toString();
  await run([
    if (p.startMs != null) ...['-ss', '${p.startMs! / 1000}'],
    if (p.endMs != null) ...['-to', '${p.endMs! / 1000}'],
    '-i', s.uri,
    '-vf', vf.join(','),
    '-c:v', p.videoCodec == 'hevc' ? 'libx265' : 'libx264',
    if (p.videoCodec == 'h264') ...['-profile:v', 'high'],
    // veryfast (not ultrafast): ultrafast disables High-profile tools.
    '-preset', 'veryfast',
    '-b:v', '${p.videoBitrate}', '-maxrate', '${(p.videoBitrate * 1.5).round()}', '-bufsize', '${p.videoBitrate * 2}',
    '-g', gop, '-keyint_min', gop, '-sc_threshold', '0',
    '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
    '-fps_mode', 'cfr', '-r', '${p.fps}',
    ...switch (p.audioMode) {
      'none' => ['-an'],
      'copy' => ['-c:a', 'copy'],
      _ => ['-c:a', 'aac', '-b:a', '${p.audioBitrate}', '-ar', '${p.audioSampleRate}', '-ac', '${math.min(2, s.audioChannels ?? 2)}'],
    },
    // Deliberately no +faststart: ensureFastStart() must fix the layout.
    out,
  ]);
}

Future<void> assertDecodes(String path) async {
  final r = await Process.run('ffmpeg', ['-v', 'error', '-i', path, '-f', 'null', '-']);
  expect(r.exitCode, 0, reason: 'decode failed');
  expect((r.stderr as String).trim(), isEmpty, reason: 'decoder errors: ${r.stderr}');
}

void main() {
  late Directory dir;
  setUpAll(() async {
    if (!hasFfmpeg) return;
    dir = await Directory.systemTemp.createTemp('hdclean_ref');
  });
  tearDownAll(() async {
    if (hasFfmpeg) await dir.delete(recursive: true);
  });

  Future<(VideoInfo, PlanResult, Mp4Report)> pipeline(String src, Preset preset, {PlanOptions Function(PlanOptions)? tweak}) async {
    final info = await probe(src);
    var o = PlanOptions(preset: preset);
    if (tweak != null) o = tweak(o);
    final r = planEncode(info, o);
    final out = '${dir.path}/${src.split('/').last}.out.mp4';
    await encode(info, r.parts.first, out);
    final before = await inspectMp4(out);
    final fixed = await ensureFastStart(out);
    expect(fixed || before.fastStart, isTrue);
    await assertDecodes(out);
    return (info, r, await inspectMp4(out));
  }

  test('4K HLG HDR 10-bit HEVC 60 fps (portrait) → TikTok HD', () async {
    final src = '${dir.path}/hdr4k.mp4';
    await run([
      '-f', 'lavfi', '-i', 'testsrc2=size=2160x3840:rate=60:duration=1',
      '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100:duration=1',
      '-c:v', 'libx265', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p10le', '-b:v', '40M',
      '-x265-params', 'log-level=error:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc',
      '-color_primaries', 'bt2020', '-color_trc', 'arib-std-b67', '-colorspace', 'bt2020nc',
      '-c:a', 'aac', '-b:a', '128k', '-tag:v', 'hvc1', src,
    ]);
    final (info, r, rep) = await pipeline(src, Preset.tiktokHd);
    expect(info.hdr, 'HLG');
    expect(info.bitDepth, 10);
    expect(r.plan.toneMapHdr, isTrue);
    final v = rep.video!;
    expect((v.width, v.height), (1080, 1920));
    expect(v.profileName, 'High');
    expect(v.constantFrameRate, isTrue);
    expect(v.fps, closeTo(60, 0.01));
    expect(v.isBt709, isTrue);
    expect(v.isHdrTransfer, isFalse);
    expect(rep.audio!.sampleRate, 48000);
    expect(rep.fastStart, isTrue);
  }, skip: !hasFfmpeg, timeout: const Timeout(Duration(minutes: 3)));

  test('720p landscape VFR, 44.1 kHz audio → CFR, native res, 48 kHz', () async {
    final src = '${dir.path}/vfr720.mp4';
    await run([
      '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=30:duration=4',
      '-f', 'lavfi', '-i', 'sine=frequency=330:sample_rate=44100:duration=4',
      // Jitter every third frame's timestamp: typical phone/screen-recorder VFR.
      '-vf', "settb=1/90000,setpts='(N/30+if(eq(mod(N,3),0),0.011,0))/TB'", '-fps_mode', 'passthrough',
      '-enc_time_base:v', '1/90000', '-video_track_timescale', '90000',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-b:v', '5M', '-c:a', 'aac', '-b:a', '128k', src,
    ]);
    final (info, r, rep) = await pipeline(src, Preset.tiktokHd);
    expect(info.isVfr, isTrue, reason: 'VFR detector');
    expect(r.plan.convertToCfr, isTrue);
    final v = rep.video!;
    expect((v.width, v.height), (1280, 720), reason: 'no upscale, orientation kept');
    expect(v.constantFrameRate, isTrue);
    expect(rep.audio!.sampleRate, 48000);
    expect(rep.fastStart, isTrue);
  }, skip: !hasFfmpeg, timeout: const Timeout(Duration(minutes: 3)));

  test('landscape Fit 9:16 produces a 9:16 canvas', () async {
    final src = '${dir.path}/land1080.mp4';
    await run([
      '-f', 'lavfi', '-i', 'testsrc2=size=1920x1080:rate=30:duration=2',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-b:v', '12M', src,
    ]);
    final (_, r, rep) = await pipeline(src, Preset.instagram, tweak: (o) => o.copyWith(frameMode: FrameMode.fit));
    expect(r.plan.audioMode, 'none');
    expect((rep.video!.width, rep.video!.height), (1080, 1920));
    expect(rep.audio, isNull);
  }, skip: !hasFfmpeg, timeout: const Timeout(Duration(minutes: 3)));

  test('already-optimal 1080×1920 H.264 master → remux only, fast-start fixed', () async {
    final src = '${dir.path}/optimal.mp4';
    await run([
      '-f', 'lavfi', '-i', 'testsrc2=size=1080x1920:rate=30:duration=2',
      '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=2',
      '-c:v', 'libx264', '-profile:v', 'high', '-preset', 'ultrafast', '-b:v', '14M', '-minrate', '14M', '-maxrate', '14M', '-bufsize', '14M',
      '-c:a', 'aac', '-b:a', '256k', src,
    ]);
    final info = await probe(src);
    final r = planEncode(info, const PlanOptions(preset: Preset.tiktokHd));
    expect(r.alreadyOptimized, isTrue, reason: r.decisions.join('\n'));
    final (_, _, rep) = await pipeline(src, Preset.tiktokHd);
    expect(rep.fastStart, isTrue);
    expect((rep.video!.width, rep.video!.height), (1080, 1920));
  }, skip: !hasFfmpeg, timeout: const Timeout(Duration(minutes: 3)));

  test('WhatsApp split: every part is a valid ≤60 s file', () async {
    final src = '${dir.path}/long.mp4';
    await run([
      '-f', 'lavfi', '-i', 'testsrc2=size=540x960:rate=30:duration=130',
      '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=130',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-b:v', '1M', '-c:a', 'aac', '-b:a', '128k', src,
    ]);
    final info = await probe(src);
    final r = planEncode(info, const PlanOptions(preset: Preset.whatsapp));
    expect(r.parts.length, 3);
    for (var i = 0; i < r.parts.length; i++) {
      final out = '${dir.path}/part$i.mp4';
      await encode(info, r.parts[i], out);
      await ensureFastStart(out);
      final rep = await inspectMp4(out);
      expect(rep.fastStart, isTrue);
      expect(rep.durationMs, lessThanOrEqualTo(60500));
      expect(rep.durationMs, greaterThan(40000));
    }
  }, skip: !hasFfmpeg, timeout: const Timeout(Duration(minutes: 5)));
}
