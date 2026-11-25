// Renders the real screens with a mocked native channel and writes PNGs to
// build/screenshots for design review. Opt-in:
//   SCREENSHOTS=1 SHOTS_ASSETS=/path/with/portrait.jpg,blocky.jpg,out.mp4 flutter test test/screenshots_test.dart
@Tags(['screenshots'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hd_clean/engine/models.dart';
import 'package:hd_clean/engine/mp4_inspector.dart';
import 'package:hd_clean/engine/planner.dart';
import 'package:hd_clean/engine/presets.dart';
import 'package:hd_clean/services/history_store.dart';
import 'package:hd_clean/services/job_runner.dart';
import 'package:hd_clean/ui/screens/analyze_screen.dart';
import 'package:hd_clean/ui/screens/compare_screen.dart';
import 'package:hd_clean/ui/screens/home_screen.dart';
import 'package:hd_clean/ui/screens/processing_screen.dart';
import 'package:hd_clean/ui/screens/result_screen.dart';
import 'package:hd_clean/ui/theme.dart';
import 'package:material_ui/material_ui.dart';

final enabled = Platform.environment['SCREENSHOTS'] == '1';
final assets = Platform.environment['SHOTS_ASSETS'] ?? '/tmp/claude-0/shots';

const hdrSource = {
  'uri': '/tmp/IMG_4821.MOV',
  'name': 'IMG_4821.MOV',
  'sizeBytes': 187654321,
  'width': 3840,
  'height': 2160,
  'rotation': 90,
  'durationMs': 34500,
  'fps': 29.6,
  'videoBitrate': 42800000,
  'videoCodec': 'hvc1',
  'videoProfile': 'Main 10',
  'bitDepth': 10,
  'hdr': 'HLG',
  'isVfr': true,
  'minFps': 24.1,
  'maxFps': 30.0,
  'hasAudio': true,
  'audioCodec': 'aac',
  'audioSampleRate': 44100,
  'audioChannels': 2,
  'audioBitrate': 186000,
};

Future<void> loadFonts() async {
  const dir = '/opt/sdk/flutter/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final w in ['Regular', 'Medium', 'Bold', 'Black']) {
    roboto.addFont(File('$dir/Roboto-$w.ttf').readAsBytes().then((b) => ByteData.sublistView(b)));
  }
  await roboto.load();
  for (final fam in ['MaterialIcons', 'packages/material_ui/MaterialIcons']) {
    final icons = FontLoader(fam)..addFont(File('$dir/MaterialIcons-Regular.otf').readAsBytes().then((b) => ByteData.sublistView(b)));
    await icons.load();
  }
}

Future<void> shot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 1500));
  await tester.pump(const Duration(milliseconds: 600));
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
  await tester.runAsync(() async {
    final img = await boundary.toImage(pixelRatio: 1.5);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    final f = File('build/screenshots/$name.png')..createSync(recursive: true);
    await f.writeAsBytes(png!.buffer.asUint8List());
  });
}

Widget app(Widget home) => RepaintBoundary(
      key: const ValueKey('shot'),
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: HD.theme().copyWith(textTheme: HD.theme().textTheme.apply(fontFamily: 'Roboto')), home: home),
    );

void main() {
  setUpAll(() async {
    if (!enabled) return;
    await loadFonts();
    final base = await Directory.systemTemp.createTemp('shots');
    await HistoryStore.instance.init(baseDir: base);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('hdclean/engine'),
      (call) async => switch (call.method) {
        'probe' => hdrSource,
        'frame' => File('$assets/${(call.arguments as Map)['uri'].toString().endsWith('.mp4') ? 'portrait' : 'blocky'}.jpg').readAsBytesSync(),
        'freeSpace' => 50000000000,
        'export' => Future<Object?>.delayed(const Duration(days: 1)),
        _ => null,
      },
    );
  });

  void setSize(WidgetTester t, double h) {
    t.view.physicalSize = Size(430 * 2, h * 2);
    t.view.devicePixelRatio = 2;
  }

  testWidgets('home', (t) async {
    setSize(t, 1400);
    final s = VideoInfo.fromMap(hdrSource);
    final store = HistoryStore.instance;
    final thumb = '$assets/portrait.jpg';
    store.entries
      ..clear()
      ..addAll([
        HistoryEntry(id: 'a', createdAt: DateTime.now(), source: s, presetTitle: 'TikTok HD', qualityLabel: 'Balanced HD', status: 'done',
            thumbPath: thumb, outputs: const [OutputFile('/x.mp4', 61234567)], outWidth: 1080, outHeight: 1920),
        HistoryEntry(id: 'b', createdAt: DateTime.now(), source: s, presetTitle: 'WhatsApp HD', qualityLabel: 'Balanced HD', status: 'done',
            thumbPath: thumb, outputs: const [OutputFile('/y.mp4', 12000000), OutputFile('/z.mp4', 9000000)], outWidth: 1080, outHeight: 1920),
        HistoryEntry(id: 'c', createdAt: DateTime.now(), source: s, presetTitle: 'Instagram HD', qualityLabel: 'Maximum Quality', status: 'cancelled', thumbPath: thumb),
      ]);
    await t.pumpWidget(app(const HomeScreen()));
    await shot(t, '1_home');
  }, skip: !enabled);

  testWidgets('analyze', (t) async {
    setSize(t, 3300);
    await t.pumpWidget(app(const AnalyzeScreen(uri: '/tmp/IMG_4821.MOV', initialPreset: Preset.tiktokHd)));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await shot(t, '2_analyze');
  }, skip: !enabled);

  testWidgets('processing', (t) async {
    setSize(t, 932);
    final s = VideoInfo.fromMap(hdrSource);
    final r = planEncode(s, const PlanOptions(preset: Preset.tiktokHd));
    await t.pumpWidget(app(ProcessingScreen(source: s, result: r, preset: Preset.tiktokHd, quality: QualityMode.balanced)));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await shot(t, '3_processing');
  }, skip: !enabled);

  testWidgets('result', (t) async {
    setSize(t, 2050);
    final s = VideoInfo.fromMap(hdrSource);
    final out = '$assets/out.mp4';
    final rep = await t.runAsync(() => inspectMp4(out));
    final e = HistoryEntry(id: 'r', createdAt: DateTime.now(), source: s, presetTitle: 'TikTok HD', qualityLabel: 'Balanced HD', status: 'done',
        outputs: [OutputFile(out, File(out).lengthSync())], outWidth: 1080, outHeight: 1920, outFps: 30, outCodec: 'h264', outBitrate: 14400000, processingMs: 41200);
    await t.pumpWidget(app(ResultScreen(entry: e, verified: [VerifiedOutput(e.outputs.first, rep)], preset: Preset.tiktokHd)));
    await shot(t, '4_result');
  }, skip: !enabled);

  testWidgets('compare', (t) async {
    setSize(t, 1500);
    final s = VideoInfo.fromMap(hdrSource);
    final out = '$assets/out.mp4';
    final rep = await t.runAsync(() => inspectMp4(out));
    await t.pumpWidget(app(CompareScreen(source: s, outputPath: out, outputSize: File(out).lengthSync(), report: rep, partStartMs: 0)));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pump();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await shot(t, '5_compare');
  }, skip: !enabled);
}
