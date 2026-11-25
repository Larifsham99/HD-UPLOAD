// Persistent export history (JSON file in the app's private support folder).

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../engine/models.dart';

class OutputFile {
  const OutputFile(this.path, this.sizeBytes);
  final String path;
  final int sizeBytes;
  Map<String, Object?> toJson() => {'path': path, 'size': sizeBytes};
  static OutputFile fromJson(Map<String, Object?> j) => OutputFile(j['path'] as String, (j['size'] as num).toInt());
}

class HistoryEntry {
  HistoryEntry({
    required this.id,
    required this.createdAt,
    required this.source,
    required this.presetTitle,
    required this.qualityLabel,
    this.thumbPath,
    this.status = 'processing',
    this.outputs = const [],
    this.outWidth,
    this.outHeight,
    this.outFps,
    this.outCodec,
    this.outBitrate,
    this.processingMs,
    this.error,
    this.remuxOnly = false,
    this.platform = 'Any',
    this.frameMode = 'keep',
  });

  final String id;
  final DateTime createdAt;
  final VideoInfo source;
  final String presetTitle;
  final String qualityLabel;
  String platform;
  String frameMode;
  String? thumbPath;

  /// processing | done | failed | cancelled | interrupted
  String status;
  List<OutputFile> outputs;
  int? outWidth, outHeight;
  double? outFps;
  String? outCodec;
  int? outBitrate;
  int? processingMs;
  String? error;
  bool remuxOnly;

  int get outputBytes => outputs.fold(0, (a, o) => a + o.sizeBytes);

  Map<String, Object?> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'source': source.toMap(),
        'presetTitle': presetTitle,
        'qualityLabel': qualityLabel,
        'platform': platform,
        'thumbPath': thumbPath,
        'status': status,
        'outputs': outputs.map((o) => o.toJson()).toList(),
        'outWidth': outWidth,
        'outHeight': outHeight,
        'outFps': outFps,
        'outCodec': outCodec,
        'outBitrate': outBitrate,
        'processingMs': processingMs,
        'error': error,
        'remuxOnly': remuxOnly,
        'frameMode': frameMode,
      };

  static HistoryEntry fromJson(Map<String, Object?> j) => HistoryEntry(
        id: j['id'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        source: VideoInfo.fromMap(j['source'] as Map<String, Object?>),
        presetTitle: j['presetTitle'] as String,
        qualityLabel: (j['qualityLabel'] as String?) ?? '',
        platform: (j['platform'] as String?) ?? 'Any',
        thumbPath: j['thumbPath'] as String?,
        status: j['status'] as String,
        outputs: ((j['outputs'] as List?) ?? const [])
            .map((o) => OutputFile.fromJson((o as Map).cast<String, Object?>()))
            .toList(),
        outWidth: (j['outWidth'] as num?)?.toInt(),
        outHeight: (j['outHeight'] as num?)?.toInt(),
        outFps: (j['outFps'] as num?)?.toDouble(),
        outCodec: j['outCodec'] as String?,
        outBitrate: (j['outBitrate'] as num?)?.toInt(),
        processingMs: (j['processingMs'] as num?)?.toInt(),
        error: j['error'] as String?,
        remuxOnly: (j['remuxOnly'] as bool?) ?? false,
        frameMode: (j['frameMode'] as String?) ?? 'keep',
      );
}

class HistoryStore {
  HistoryStore._();
  static final instance = HistoryStore._();

  late Directory root;
  late Directory exportsDir;
  late Directory tempDir;
  late Directory thumbsDir;
  final List<HistoryEntry> entries = [];

  File get _file => File('${root.path}/history.json');

  /// Loads history and recovers from a previous crash or forced close:
  /// half-written exports are deleted and their entries marked "interrupted".
  Future<void> init({Directory? baseDir}) async {
    root = baseDir ?? await getApplicationSupportDirectory();
    exportsDir = await Directory('${root.path}/exports').create(recursive: true);
    tempDir = Directory('${exportsDir.path}/.partial');
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
    await tempDir.create(recursive: true);
    thumbsDir = await Directory('${root.path}/thumbs').create(recursive: true);

    entries.clear();
    if (await _file.exists()) {
      try {
        final list = jsonDecode(await _file.readAsString()) as List;
        entries.addAll(list.map((e) => HistoryEntry.fromJson((e as Map).cast<String, Object?>())));
      } catch (_) {
        // Corrupt history: keep a copy for diagnostics and start fresh.
        await _file.rename('${_file.path}.corrupt');
      }
    }
    var changed = false;
    for (final e in entries) {
      if (e.status == 'processing') {
        e.status = 'interrupted';
        e.error = 'The app was closed while processing. The original video was not modified.';
        changed = true;
      }
      // Drop outputs the user deleted outside the app.
      final kept = e.outputs.where((o) => File(o.path).existsSync()).toList();
      if (kept.length != e.outputs.length) {
        e.outputs = kept;
        changed = true;
      }
    }
    if (changed) await save();
  }

  Future<void> save() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(entries.map((e) => e.toJson()).toList()), flush: true);
    await tmp.rename(_file.path);
  }

  Future<void> upsert(HistoryEntry e) async {
    final i = entries.indexWhere((x) => x.id == e.id);
    if (i >= 0) {
      entries[i] = e;
    } else {
      entries.insert(0, e);
    }
    await save();
  }

  /// Deletes HD CLEAN's exported copies. Never touches the original video.
  Future<void> remove(HistoryEntry e) async {
    for (final o in e.outputs) {
      final f = File(o.path);
      if (await f.exists()) await f.delete();
    }
    if (e.thumbPath != null) {
      final t = File(e.thumbPath!);
      if (await t.exists()) await t.delete();
    }
    entries.removeWhere((x) => x.id == e.id);
    await save();
  }
}
