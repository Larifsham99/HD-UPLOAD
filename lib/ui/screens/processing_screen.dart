import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../engine/models.dart';
import '../../engine/planner.dart';
import '../../engine/presets.dart';
import '../../services/job_runner.dart';
import '../theme.dart';
import '../widgets.dart';
import 'result_screen.dart';

class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({super.key, required this.source, required this.result, required this.preset, required this.quality, this.thumbnail});
  final VideoInfo source;
  final PlanResult result;
  final Preset preset;
  final QualityMode quality;
  final Uint8List? thumbnail;
  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  late final JobRunner _job = JobRunner(
    source: widget.source,
    result: widget.result,
    preset: widget.preset,
    quality: widget.quality,
    thumbnail: widget.thumbnail,
  );
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _job.addListener(_onChange);
    _job.run();
  }

  void _onChange() {
    if (!mounted) return;
    if (_job.done && !_navigated) {
      _navigated = true;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => ResultScreen(entry: _job.entry!, verified: _job.outputs, preset: widget.preset),
      ));
      return;
    }
    if (_job.cancelled && !_navigated) {
      _navigated = true;
      Navigator.of(context).pop();
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _job.removeListener(_onChange);
    _job.dispose();
    super.dispose();
  }

  Future<void> _confirmCancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: HD.surface,
        title: const Text('Cancel optimization?'),
        content: const Text('The partial file will be deleted. Your original video is safe and unchanged.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Continue')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Cancel', style: TextStyle(color: HD.bad))),
        ],
      ),
    );
    if (ok == true) await _job.cancel();
  }

  String _fmtDur(Duration d) {
    final s = d.inSeconds;
    if (s < 60) return '${s}s';
    return '${s ~/ 60}m ${(s % 60).toString().padLeft(2, '0')}s';
  }

  @override
  Widget build(BuildContext context) {
    final j = _job;
    final failed = j.error != null;
    final pct = j.percent;
    final waiting = j.stage == JobStage.analyzing || j.stage == JobStage.preparing && pct == 0;
    return PopScope(
      canPop: failed,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmCancel();
      },
      child: Scaffold(
        body: HDBackground(
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
              child: Column(children: [
                Row(children: [
                  const BrandMark(size: 30),
                  const SizedBox(width: 10),
                  Text(widget.preset.title.toUpperCase(), style: kTitle),
                  const Spacer(),
                  if (j.partCount > 1) Text('PART ${j.partIndex + 1 > j.partCount ? j.partCount : j.partIndex + 1} / ${j.partCount}', style: kTitle.copyWith(color: HD.cyan)),
                ]),
                const Spacer(),
                if (failed) _failure() else ...[
                  ProgressRing(
                    value: pct / 100,
                    indeterminate: waiting,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(waiting ? '—' : '${pct.floor()}%',
                          style: const TextStyle(fontSize: 52, fontWeight: FontWeight.w900, letterSpacing: -1.5)),
                      const SizedBox(height: 2),
                      Text(j.cancelling ? 'Cancelling…' : j.stage.label, style: const TextStyle(color: HD.muted, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                  const SizedBox(height: 28),
                  GlassCard(
                    child: StatGrid([
                      ('Speed', j.speed == null ? 'Measuring…' : '${j.speed!.toStringAsFixed(j.speed! < 10 ? 1 : 0)}× real-time'),
                      ('Time remaining', j.eta == null ? 'Estimating…' : _fmtDur(j.eta!)),
                      ('Original size', formatBytes(widget.source.sizeBytes)),
                      ('Target size', '≈ ${formatBytes(widget.result.estimatedBytes)}'),
                      ('Elapsed', _fmtDur(j.elapsed)),
                      ('Output', '${widget.result.plan.width}×${widget.result.plan.height}'),
                    ]),
                  ),
                ],
                const SizedBox(height: 18),
                if (!failed) _stages(),
                const Spacer(),
                if (failed)
                  GradientButton(label: 'BACK', onPressed: () => Navigator.pop(context))
                else
                  SecondaryButton(
                    label: j.cancelling ? 'Cancelling…' : 'Cancel',
                    icon: Icons.close_rounded,
                    onPressed: j.cancelling ? null : _confirmCancel,
                  ),
                const SizedBox(height: 8),
                const Text('Keep HD CLEAN open for the fastest processing.', style: TextStyle(color: HD.faint, fontSize: 12)),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _failure() => GlassCard(
        child: Column(children: [
          const Icon(Icons.error_outline_rounded, color: HD.bad, size: 44),
          const SizedBox(height: 12),
          const Text('Optimization failed', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          const SizedBox(height: 8),
          Text(_job.error!, textAlign: TextAlign.center, style: const TextStyle(color: HD.muted, height: 1.4)),
          const SizedBox(height: 8),
          const Text('Your original video was not modified.', style: TextStyle(color: HD.ok, fontSize: 12.5)),
        ]),
      );

  Widget _stages() {
    final j = _job;
    final audioMode = widget.result.plan.audioMode;
    final remux = widget.result.alreadyOptimized;
    // Each stage: (label, state) where state 0 = pending, 1 = active, 2 = done.
    int st(JobStage s) {
      final cur = j.stage.index;
      if (s == JobStage.analyzing) return 2;
      if (s == JobStage.audio) {
        if (audioMode != 'transcode') return cur >= JobStage.video.index ? 2 : 0;
        return cur == JobStage.video.index ? 1 : (cur > JobStage.video.index ? 2 : 0);
      }
      if (s.index < cur) return 2;
      if (s.index == cur) return 1;
      return 0;
    }

    String label(JobStage s) {
      if (s == JobStage.video && remux) return 'Re-packaging video (no re-encode)';
      if (s == JobStage.audio && audioMode == 'copy') return 'Audio kept original';
      if (s == JobStage.audio && audioMode == 'none') return 'No audio track';
      return s.label;
    }

    return Column(children: [
      for (final s in JobStage.values)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: switch (st(s)) {
                2 => const Icon(Icons.check_circle_rounded, key: ValueKey(2), color: HD.ok, size: 18),
                1 => const SizedBox(key: ValueKey(1), width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: HD.cyan)),
                _ => const Icon(Icons.circle_outlined, key: ValueKey(0), color: HD.faint, size: 18),
              },
            ),
            const SizedBox(width: 12),
            Text(label(s),
                style: TextStyle(
                    color: st(s) == 0 ? HD.faint : HD.text, fontWeight: st(s) == 1 ? FontWeight.w700 : FontWeight.w500, fontSize: 13.5)),
          ]),
        ),
    ]);
  }
}
