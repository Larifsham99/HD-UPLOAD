// TikTok Preview: encodes the same 6-second moment twice with an
// approximation of TikTok's delivery compression — once from the original,
// once from the HD CLEAN file — and opens the before/after slider on the two
// results. This shows, before posting, how each version is likely to hold up.

import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../engine/models.dart';
import '../../engine/mp4_inspector.dart';
import '../../engine/tiktok_sim.dart';
import '../../services/history_store.dart';
import '../../services/native_engine.dart';
import '../theme.dart';
import '../widgets.dart';
import 'compare_screen.dart';

class TikTokPreviewScreen extends StatefulWidget {
  const TikTokPreviewScreen({super.key, required this.entry, required this.outputPath, this.partStartMs = 0});
  final HistoryEntry entry;
  final String outputPath;
  final int partStartMs;
  @override
  State<TikTokPreviewScreen> createState() => _TikTokPreviewScreenState();
}

class _TikTokPreviewScreenState extends State<TikTokPreviewScreen> {
  final _engine = NativeEngine.instance;
  int _step = 0; // 0 = original, 1 = HD CLEAN
  double _pct = 0;
  String? _error;
  String? _currentJob;
  final _files = <String>[];

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    if (_currentJob != null) _engine.cancel(_currentJob!).catchError((_) {});
    for (final f in _files) {
      try {
        File(f).deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  Future<void> _run() async {
    final sub = _engine.progress.listen((p) {
      if (p.jobId == _currentJob && p.percent >= 0 && mounted) setState(() => _pct = p.percent);
    });
    try {
      final store = HistoryStore.instance;
      final out = await _engine.probe(widget.outputPath);
      final src = widget.entry.source;
      final id = DateTime.now().millisecondsSinceEpoch;
      final simB = tiktokSimulationPlan(
          width: out.displayWidth, height: out.displayHeight, fps: out.fps, durationMs: out.durationMs);
      final offset = widget.partStartMs;
      final simA = EncodePlan(
        width: simB.width,
        height: simB.height,
        contentWidth: simB.width,
        contentHeight: simB.height,
        frameMode: FrameMode.values.firstWhere((m) => m.name == widget.entry.frameMode, orElse: () => FrameMode.keep),
        fps: simB.fps,
        convertToCfr: true,
        videoCodec: 'h264',
        videoBitrate: simB.videoBitrate,
        keyframeIntervalSec: simB.keyframeIntervalSec,
        toneMapHdr: src.isHdr || src.bitDepth > 8,
        audioMode: 'none',
        audioBitrate: 0,
        audioSampleRate: 48000,
        remuxOnly: false,
        upscaled: false,
        startMs: offset + simB.startMs!,
        endMs: offset + simB.endMs!,
      );
      final aPath = '${store.tempDir.path}/sim_${id}_original.mp4';
      final bPath = '${store.tempDir.path}/sim_${id}_hdclean.mp4';
      _files.addAll([aPath, bPath]);

      _currentJob = 'sim-a-$id';
      await _engine.export(jobId: _currentJob!, inputUri: src.uri, outputPath: aPath, plan: simA, source: src);
      if (!mounted) return;
      setState(() {
        _step = 1;
        _pct = 0;
      });
      _currentJob = 'sim-b-$id';
      await _engine.export(jobId: _currentJob!, inputUri: widget.outputPath, outputPath: bPath, plan: simB, source: out);
      _currentJob = null;
      final aInfo = await _engine.probe(aPath);
      final bReport = await inspectMp4(bPath);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => CompareScreen(
          source: aInfo,
          outputPath: bPath,
          outputSize: File(bPath).lengthSync(),
          report: bReport,
          partStartMs: 0,
          title: 'TikTok Preview',
          beforeLabel: 'ORIGINAL → TIKTOK',
          afterLabel: 'HD CLEAN → TIKTOK',
          note: 'Both sides were compressed on this phone the way TikTok approximately does '
              '(H.264 about ${formatBitrate(simB.videoBitrate)}). TikTok\'s exact settings are not public, so treat this as a guide.',
          onDispose: () {
            for (final f in [aPath, bPath]) {
              try {
                File(f).deleteSync();
              } catch (_) {}
            }
          },
        ),
      ));
      _files.clear();
    } on EngineException catch (e) {
      if (mounted && !e.cancelled) setState(() => _error = e.message);
    } finally {
      await sub.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: HDBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(children: [
              Row(children: [
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
                const Text('TikTok Preview', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
              ]),
              const Spacer(),
              if (_error != null)
                GlassCard(child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: HD.warn)))
              else ...[
                ProgressRing(
                  value: (_step * 100 + _pct) / 200,
                  size: 200,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('${((_step * 100 + _pct) / 2).floor()}%', style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w900)),
                    Text(_step == 0 ? 'Simulating original' : 'Simulating HD CLEAN', style: const TextStyle(color: HD.muted)),
                  ]),
                ),
                const SizedBox(height: 26),
                const Text(
                  'Compressing a 6-second clip of both versions the way TikTok roughly does, so you can see which one survives better before you post.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: HD.muted, height: 1.45),
                ),
              ],
              const Spacer(),
            ]),
          ),
        ),
      ),
    );
  }
}
