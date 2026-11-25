// Runs one optimization job (one or more output parts) through the native
// engine, tracks real progress, verifies the output and records history.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../engine/models.dart';
import '../engine/mp4_inspector.dart';
import '../engine/planner.dart';
import '../engine/presets.dart';
import 'history_store.dart';
import 'native_engine.dart';

enum JobStage { analyzing, preparing, video, audio, finalizing, saving }

extension JobStageLabel on JobStage {
  String get label => switch (this) {
        JobStage.analyzing => 'Analyzing video',
        JobStage.preparing => 'Preparing encoding',
        JobStage.video => 'Optimizing video',
        JobStage.audio => 'Optimizing audio',
        JobStage.finalizing => 'Finalizing MP4',
        JobStage.saving => 'Saving video',
      };
}

class VerifiedOutput {
  const VerifiedOutput(this.file, this.report);
  final OutputFile file;
  final Mp4Report? report;
}

class JobRunner extends ChangeNotifier {
  JobRunner({
    required this.source,
    required this.result,
    required this.preset,
    required this.quality,
    this.thumbnail,
  });

  final VideoInfo source;
  final PlanResult result;
  final Preset preset;
  final QualityMode quality;
  final Uint8List? thumbnail;

  final _engine = NativeEngine.instance;
  final _store = HistoryStore.instance;

  late final String id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  HistoryEntry? entry;

  JobStage stage = JobStage.analyzing;
  double percent = 0;
  int partIndex = 0;
  int get partCount => result.parts.length;

  /// Media time processed per wall-clock second (1.0 = real time).
  double? speed;
  Duration? eta;
  Duration elapsed = Duration.zero;
  bool cancelling = false;
  String? error;
  String? fallbackNote;
  bool done = false;
  bool cancelled = false;
  final List<VerifiedOutput> outputs = [];

  final _clock = Stopwatch();
  StreamSubscription<EngineProgress>? _sub;
  Timer? _ticker;
  String? _currentJob;

  int _partDurationMs(EncodePlan p) =>
      (p.endMs ?? source.durationMs) - (p.startMs ?? 0);

  Future<void> run() async {
    _clock.start();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      elapsed = _clock.elapsed;
      notifyListeners();
    });
    await _engine.keepAwake(true).catchError((_) {});

    // Low-storage guard before writing anything.
    final free = await _engine.freeSpaceBytes().catchError((_) => -1);
    final needed = (result.estimatedBytes * 1.15).round() + 50 * 1024 * 1024;
    if (free >= 0 && free < needed) {
      _fail('Not enough free storage. About ${formatBytes(needed)} is needed, '
          '${formatBytes(free)} is available. Free some space and try again.');
      return;
    }

    String? thumbPath;
    if (thumbnail != null) {
      thumbPath = '${_store.thumbsDir.path}/$id.jpg';
      await File(thumbPath).writeAsBytes(thumbnail!);
    }
    entry = HistoryEntry(
      id: id,
      createdAt: DateTime.now(),
      source: source,
      presetTitle: preset.title,
      qualityLabel: quality.label,
      platform: preset.platform,
      thumbPath: thumbPath,
      remuxOnly: result.alreadyOptimized,
      frameMode: result.plan.frameMode.name,
    );
    await _store.upsert(entry!);

    stage = JobStage.preparing;
    notifyListeners();

    final totalMs = result.parts.fold<int>(0, (a, p) => a + _partDurationMs(p));
    var doneMs = 0;

    _sub = _engine.progress.listen((p) {
      if (p.jobId != _currentJob) return;
      final part = result.parts[partIndex];
      final partMs = _partDurationMs(part);
      if (p.stage == 'preparing') {
        stage = JobStage.preparing;
      } else if (p.stage == 'encoding') {
        stage = JobStage.video;
      } else if (p.stage == 'finalizing') {
        stage = JobStage.finalizing;
      }
      if (p.percent >= 0) {
        final processed = doneMs + partMs * p.percent / 100;
        percent = (processed / totalMs * 100).clamp(0, 100).toDouble();
        final secs = _clock.elapsedMilliseconds / 1000;
        if (secs > 1 && processed > 0) {
          speed = processed / 1000 / secs;
          final remainingMs = (totalMs - processed) / speed!;
          eta = Duration(milliseconds: remainingMs.round());
        }
      }
      notifyListeners();
    });

    try {
      for (partIndex = 0; partIndex < result.parts.length; partIndex++) {
        if (cancelling) throw EngineException('cancelled', 'Cancelled');
        final part = result.parts[partIndex];
        final suffix = partCount > 1 ? '_part${partIndex + 1}' : '';
        final name = 'HDCLEAN_${preset.platform.toUpperCase()}_$id$suffix.mp4';
        final tmp = '${_store.tempDir.path}/$name';
        final dest = '${_store.exportsDir.path}/$name';
        _currentJob = '$id-$partIndex';
        final r = await _engine.export(jobId: _currentJob!, inputUri: source.uri, outputPath: tmp, plan: part, source: source);
        if (r.fallbackNote != null) fallbackNote = r.fallbackNote;
        stage = JobStage.finalizing;
        notifyListeners();
        // Guarantee the MP4 index sits before the media data.
        try {
          await ensureFastStart(r.path);
        } catch (_) {
          // The file is still valid; verification will report the layout.
        }
        stage = JobStage.saving;
        notifyListeners();
        // Move into the library only once complete: a partial file can never
        // be mistaken for a finished export.
        final moved = await File(r.path).rename(dest);
        Mp4Report? report;
        try {
          report = await inspectMp4(moved.path);
        } catch (_) {
          report = null;
        }
        outputs.add(VerifiedOutput(OutputFile(moved.path, await moved.length()), report));
        doneMs += _partDurationMs(part);
      }
      stage = JobStage.saving;
      percent = 100;
      final v = outputs.first.report?.video;
      entry!
        ..status = 'done'
        ..outputs = outputs.map((o) => o.file).toList()
        ..outWidth = v?.width ?? result.plan.width
        ..outHeight = v?.height ?? result.plan.height
        ..outFps = v?.fps ?? result.plan.fps
        ..outCodec = result.alreadyOptimized ? source.videoCodec : result.plan.videoCodec
        ..outBitrate = _measuredBitrate()
        ..processingMs = _clock.elapsedMilliseconds;
      await _store.upsert(entry!);
      done = true;
    } on EngineException catch (e) {
      if (e.cancelled || cancelling) {
        cancelled = true;
        entry!
          ..status = 'cancelled'
          ..error = 'Cancelled. The original video was not modified.';
        // Remove any finished parts of a cancelled multi-part job too.
        for (final o in outputs) {
          final f = File(o.file.path);
          if (await f.exists()) await f.delete();
        }
        outputs.clear();
        entry!.outputs = const [];
        await _store.upsert(entry!);
      } else {
        await _recordFailure(e.message);
      }
    } catch (e) {
      await _recordFailure('Processing failed: $e');
    } finally {
      await _cleanupTemp();
      await _finish();
    }
  }

  int? _measuredBitrate() {
    final bytes = outputs.fold<int>(0, (a, o) => a + o.file.sizeBytes);
    final ms = result.parts.fold<int>(0, (a, p) => a + _partDurationMs(p));
    if (ms <= 0) return null;
    return (bytes * 8 * 1000 / ms).round();
  }

  Future<void> _recordFailure(String message) async {
    error = message;
    if (entry != null) {
      entry!
        ..status = 'failed'
        ..error = message;
      await _store.upsert(entry!);
    }
  }

  void _fail(String message) {
    error = message;
    _finish();
  }

  Future<void> _cleanupTemp() async {
    try {
      await for (final f in _store.tempDir.list()) {
        if (f.path.contains(id)) await f.delete();
      }
    } catch (_) {}
  }

  Future<void> _finish() async {
    _clock.stop();
    elapsed = _clock.elapsed;
    _ticker?.cancel();
    await _sub?.cancel();
    await _engine.keepAwake(false).catchError((_) {});
    notifyListeners();
  }

  Future<void> cancel() async {
    if (done || cancelling) return;
    cancelling = true;
    notifyListeners();
    if (_currentJob != null) {
      await _engine.cancel(_currentJob!).catchError((_) {});
    }
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}
