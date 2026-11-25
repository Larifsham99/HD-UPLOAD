// Dart side of the native video engine.
//
// Android: Media3 Transformer (MediaCodec hardware encoders/decoders, OpenGL
// scaling + HDR tone-mapping) — android/app/src/main/kotlin/.../VideoEngine.kt
// iOS: AVAssetReader/AVAssetWriter (VideoToolbox hardware codecs) —
// ios/Runner/VideoEngine.swift

import 'dart:async';

import 'package:flutter/services.dart';

import '../engine/models.dart';

class EngineProgress {
  const EngineProgress({
    required this.jobId,
    required this.stage,
    required this.percent,
    this.processedMs,
  });

  final String jobId;

  /// preparing | encoding | finalizing
  final String stage;

  /// 0–100, or -1 while the engine cannot yet report progress.
  final double percent;
  final int? processedMs;
}

class EngineResult {
  const EngineResult({
    required this.path,
    required this.sizeBytes,
    this.encoderName,
    this.transmuxed = false,
    this.fallbackNote,
  });

  final String path;
  final int sizeBytes;
  final String? encoderName;
  final bool transmuxed;

  /// Set when the device encoder could not honour every requested setting.
  final String? fallbackNote;
}

class EngineException implements Exception {
  EngineException(this.code, this.message);
  final String code;
  final String message;
  bool get cancelled => code == 'cancelled';
  @override
  String toString() => message;
}

class NativeEngine {
  NativeEngine._();
  static final instance = NativeEngine._();

  static const _channel = MethodChannel('hdclean/engine');
  static const _events = EventChannel('hdclean/progress');

  Stream<EngineProgress>? _progress;

  Stream<EngineProgress> get progress => _progress ??= _events
      .receiveBroadcastStream()
      .map((e) {
        final m = e as Map<Object?, Object?>;
        return EngineProgress(
          jobId: m['jobId'] as String,
          stage: m['stage'] as String,
          percent: (m['percent'] as num).toDouble(),
          processedMs: (m['processedMs'] as num?)?.toInt(),
        );
      })
      .asBroadcastStream();

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw EngineException(e.code, e.message ?? 'Unexpected error (${e.code}).');
    }
  }

  /// Opens the system video picker. Returns a platform URI/path, or null if cancelled.
  /// iOS uses PHPicker with the *current* representation so the original file
  /// is delivered without the picker transcoding (and degrading) it.
  Future<String?> pickVideo() => _call<String>('pickVideo');

  Future<VideoInfo> probe(String uri) async {
    final m = await _call<Map<Object?, Object?>>('probe', {'uri': uri});
    return VideoInfo.fromMap(m!);
  }

  /// JPEG thumbnail at [timeMs], longest edge ≤ [maxSize]. Exact frame when [exact].
  Future<Uint8List?> frame(String uri, {int timeMs = 0, int maxSize = 512, bool exact = false}) =>
      _call<Uint8List>('frame', {'uri': uri, 'timeMs': timeMs, 'maxSize': maxSize, 'exact': exact});

  /// Starts an export. Completes when the file is fully written (or throws).
  Future<EngineResult> export({
    required String jobId,
    required String inputUri,
    required String outputPath,
    required EncodePlan plan,
    required VideoInfo source,
  }) async {
    final m = await _call<Map<Object?, Object?>>('export', {
      'jobId': jobId,
      'input': inputUri,
      'output': outputPath,
      ...plan.toMap(),
      'sourceChannels': source.audioChannels,
      'sourceFps': source.fps,
      'sourceWidth': source.displayWidth,
      'sourceHeight': source.displayHeight,
      'durationMs': source.durationMs,
    });
    return EngineResult(
      path: m!['path'] as String,
      sizeBytes: (m['sizeBytes'] as num).toInt(),
      encoderName: m['encoderName'] as String?,
      transmuxed: (m['transmuxed'] as bool?) ?? false,
      fallbackNote: m['fallback'] as String?,
    );
  }

  Future<void> cancel(String jobId) => _call('cancel', {'jobId': jobId});

  Future<int> freeSpaceBytes() async => (await _call<num>('freeSpace'))?.toInt() ?? -1;

  /// Saves to Photos / Gallery (Movies/HD CLEAN on Android). Requests the
  /// add-only permission on iOS, and storage permission only on Android ≤ 9.
  Future<void> saveToGallery(String path) => _call('saveToGallery', {'path': path});

  /// target: tiktok | instagram | whatsapp | any
  Future<void> share(String path, String target) => _call('share', {'path': path, 'target': target});

  Future<void> keepAwake(bool on) => _call('keepAwake', {'on': on});
}
