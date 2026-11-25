// Runs the REAL native engine on a device/emulator/simulator:
// Android → Media3 Transformer + MediaCodec, iOS → AVAssetReader/Writer.
//
//   ./tool/make_fixture.sh && flutter test integration_test -d <device>
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hd_clean/engine/models.dart';
import 'package:hd_clean/engine/mp4_inspector.dart';
import 'package:hd_clean/engine/planner.dart';
import 'package:hd_clean/engine/presets.dart';
import 'package:hd_clean/services/native_engine.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'fixture_data.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final engine = NativeEngine.instance;
  late String source;
  late Directory dir;

  setUpAll(() async {
    dir = await Directory('${(await getTemporaryDirectory()).path}/hdclean_it').create(recursive: true);
    source = '${dir.path}/source.mp4';
    await File(source).writeAsBytes(base64Decode(fixtureBase64));
  });

  testWidgets('probe reads real stream properties', (_) async {
    final info = await engine.probe(source);
    expect((info.width, info.height), (1280, 720));
    expect(info.videoCodec, 'h264');
    expect(info.durationMs, inInclusiveRange(2800, 3300));
    expect(info.fps, inInclusiveRange(28, 31));
    expect(info.hasAudio, isTrue);
    expect(info.audioCodec, 'aac');
    expect(info.audioSampleRate, 44100);
    expect(info.isVfr, isTrue, reason: 'fixture has jittered timestamps');
    expect(info.isHdr, isFalse);
  });

  testWidgets('frame extraction returns a JPEG', (_) async {
    final jpg = await engine.frame(source, timeMs: 1000, maxSize: 640, exact: true);
    expect(jpg, isNotNull);
    expect(jpg!.sublist(0, 2), [0xFF, 0xD8]);
  });

  testWidgets('export: 720p landscape → Fit 9:16, CFR, AAC 48 kHz, fast-start', (_) async {
    final info = await engine.probe(source);
    final r = planEncode(info, const PlanOptions(preset: Preset.tiktokHd, frameMode: FrameMode.fit));
    expect(r.plan.remuxOnly, isFalse);
    final events = <EngineProgress>[];
    final sub = engine.progress.listen(events.add);
    final out = '${dir.path}/out_fit.mp4';
    final res = await engine.export(jobId: 'it-fit', inputUri: source, outputPath: out, plan: r.plan, source: info);
    await sub.cancel();
    await ensureFastStart(res.path);
    final rep = await inspectMp4(res.path);
    final v = rep.video!;
    // 1280 wide content fits a 1080×1920 canvas after downscale.
    expect((v.width, v.height), (r.plan.width, r.plan.height));
    expect(v.width! / v.height!, closeTo(9 / 16, 0.01));
    expect(normaliseVideoCodec(v.codec), 'h264');
    expect(v.constantFrameRate, isTrue);
    expect(v.fps, closeTo(r.plan.fps, 0.6));
    expect(v.isHdrTransfer, isFalse);
    expect(rep.audio?.sampleRate, 48000);
    expect(rep.fastStart, isTrue);
    expect(rep.durationMs, inInclusiveRange(2500, 3400));
    expect(events.where((e) => e.jobId == 'it-fit' && e.percent > 0), isNotEmpty, reason: 'real progress events');
    // ignore: avoid_print
    print('Encoder: ${res.encoderName} · profile ${v.profileName} · ${formatBytes(res.sizeBytes)} · '
        '${v.width}×${v.height} @ ${v.fps?.toStringAsFixed(2)} fps');
  });

  testWidgets('export: segment (WhatsApp part) honours start/end', (_) async {
    final info = await engine.probe(source);
    final plan = planEncode(info, const PlanOptions(preset: Preset.whatsapp)).plan.copyWith(startMs: 1000, endMs: 2500);
    final res = await engine.export(jobId: 'it-seg', inputUri: source, outputPath: '${dir.path}/seg.mp4', plan: plan, source: info);
    final rep = await inspectMp4(res.path);
    expect(rep.durationMs, inInclusiveRange(1200, 1800));
    expect(rep.video!.fps, closeTo(plan.fps, 0.6));
  });

  testWidgets('cancel stops the export and removes the partial file', (_) async {
    final info = await engine.probe(source);
    final plan = planEncode(info, const PlanOptions(preset: Preset.tiktokHd, quality: QualityMode.maximum)).plan;
    final out = '${dir.path}/cancel.mp4';
    final f = engine.export(jobId: 'it-cancel', inputUri: source, outputPath: out, plan: plan, source: info);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await engine.cancel('it-cancel');
    try {
      await f;
      // A very fast device may finish before cancel arrives; that is valid.
    } on EngineException catch (e) {
      expect(e.cancelled, isTrue);
      expect(File(out).existsSync(), isFalse);
    }
  });

  testWidgets('original file is never modified', (_) async {
    final bytes = await File(source).readAsBytes();
    expect(base64Encode(bytes), fixtureBase64);
  });
}
