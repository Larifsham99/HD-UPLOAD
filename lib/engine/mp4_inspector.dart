// Minimal ISO-BMFF (MP4/MOV) reader used to *verify* exported files:
// fast-start layout, codec profile/level, constant frame rate, colour tags,
// audio format. Reads only box headers plus the moov box, so it is cheap even
// for multi-gigabyte files.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

class Mp4Track {
  String handler = '';
  String? codec;
  int? width, height;
  int timescale = 0;
  int durationUnits = 0;
  int sampleCount = 0;
  double? fps;
  bool? constantFrameRate;
  int? profileIdc;
  int? levelIdc;
  int? colourPrimaries, transferCharacteristics, matrixCoefficients;
  bool? fullRange;
  int? channels;
  int? sampleRate;
  int rotation = 0;

  bool get isVideo => handler == 'vide';
  bool get isAudio => handler == 'soun';

  String? get profileName {
    if (profileIdc == null) return null;
    if (codec == 'avc1' || codec == 'avc3') {
      return switch (profileIdc) {
        66 => 'Baseline',
        77 => 'Main',
        88 => 'Extended',
        100 => 'High',
        110 => 'High 10',
        122 => 'High 4:2:2',
        _ => 'Profile $profileIdc',
      };
    }
    return switch (profileIdc) {
      1 => 'Main',
      2 => 'Main 10',
      _ => 'Profile $profileIdc',
    };
  }

  String? get levelName {
    if (levelIdc == null) return null;
    if (codec == 'avc1' || codec == 'avc3') return (levelIdc! / 10).toStringAsFixed(1);
    return (levelIdc! / 30).toStringAsFixed(1);
  }

  /// BT.709 primaries/transfer/matrix (1/1/1), or untagged (treated as 709 by players).
  bool get isBt709 =>
      colourPrimaries == null ||
      (colourPrimaries == 1 && (transferCharacteristics == 1 || transferCharacteristics == 6) && matrixCoefficients == 1);

  bool get isHdrTransfer => transferCharacteristics == 16 || transferCharacteristics == 18;
}

class Mp4Report {
  final List<String> topLevel = [];
  final List<Mp4Track> tracks = [];
  String? majorBrand;
  int durationMs = 0;

  /// moov is before mdat: players and upload servers can start immediately.
  bool get fastStart {
    final m = topLevel.indexOf('moov'), d = topLevel.indexOf('mdat');
    return m >= 0 && (d < 0 || m < d);
  }

  Mp4Track? get video => tracks.where((t) => t.isVideo).firstOrNull;
  Mp4Track? get audio => tracks.where((t) => t.isAudio).firstOrNull;
}

class Mp4FormatException implements Exception {
  Mp4FormatException(this.message);
  final String message;
  @override
  String toString() => 'Mp4FormatException: $message';
}

Future<Mp4Report> inspectMp4(String path) async {
  final raf = await File(path).open();
  try {
    final len = await raf.length();
    final report = Mp4Report();
    var pos = 0;
    Uint8List? moov;
    while (pos + 8 <= len) {
      await raf.setPosition(pos);
      final h = await raf.read(16);
      if (h.length < 8) break;
      final bd = ByteData.sublistView(h);
      var size = bd.getUint32(0);
      final type = String.fromCharCodes(h.sublist(4, 8));
      var header = 8;
      if (size == 1) {
        if (h.length < 16) break;
        size = bd.getUint64(8);
        header = 16;
      } else if (size == 0) {
        size = len - pos;
      }
      if (size < header) throw Mp4FormatException('Bad box size at $pos');
      report.topLevel.add(type);
      if (type == 'ftyp' && size >= 12) {
        await raf.setPosition(pos + header);
        report.majorBrand = String.fromCharCodes(await raf.read(4));
      } else if (type == 'moov') {
        if (size > 256 * 1024 * 1024) throw Mp4FormatException('moov too large');
        await raf.setPosition(pos + header);
        moov = await raf.read(size - header);
      }
      pos += size;
    }
    if (moov == null) throw Mp4FormatException('No moov box — not a complete MP4');
    _parseMoov(ByteData.sublistView(moov), report);
    return report;
  } finally {
    await raf.close();
  }
}

/// Iterates child boxes in [d] between [start] and [end].
Iterable<(String, int, int)> _boxes(ByteData d, int start, int end) sync* {
  var p = start;
  while (p + 8 <= end) {
    var size = d.getUint32(p);
    final type = String.fromCharCodes([d.getUint8(p + 4), d.getUint8(p + 5), d.getUint8(p + 6), d.getUint8(p + 7)]);
    var header = 8;
    if (size == 1) {
      size = d.getUint64(p + 8);
      header = 16;
    } else if (size == 0) {
      size = end - p;
    }
    if (size < header || p + size > end) return;
    yield (type, p + header, p + size);
    p += size;
  }
}

void _parseMoov(ByteData d, Mp4Report r) {
  for (final (type, s, e) in _boxes(d, 0, d.lengthInBytes)) {
    if (type == 'mvhd') {
      final v = d.getUint8(s);
      final ts = v == 1 ? d.getUint32(s + 20) : d.getUint32(s + 12);
      final dur = v == 1 ? d.getUint64(s + 24) : d.getUint32(s + 16);
      if (ts > 0) r.durationMs = dur * 1000 ~/ ts;
    } else if (type == 'trak') {
      final t = Mp4Track();
      _parseTrak(d, s, e, t);
      r.tracks.add(t);
    }
  }
}

void _parseTrak(ByteData d, int s, int e, Mp4Track t) {
  for (final (type, cs, ce) in _boxes(d, s, e)) {
    switch (type) {
      case 'tkhd':
        final v = d.getUint8(cs);
        final m = cs + (v == 1 ? 4 + 8 + 8 + 4 + 4 + 8 : 4 + 4 + 4 + 4 + 4 + 4) + 8 + 2 + 2 + 2 + 2;
        if (m + 16 <= ce) {
          final a = d.getInt32(m) / 65536, b = d.getInt32(m + 4) / 65536;
          final deg = (math.atan2(b, a) * 180 / math.pi).round();
          t.rotation = ((deg % 360) + 360) % 360;
        }
      case 'mdia':
        _parseContainer(d, cs, ce, t);
    }
  }
}

void _parseContainer(ByteData d, int s, int e, Mp4Track t) {
  for (final (type, cs, ce) in _boxes(d, s, e)) {
    switch (type) {
      case 'mdhd':
        final v = d.getUint8(cs);
        t.timescale = v == 1 ? d.getUint32(cs + 20) : d.getUint32(cs + 12);
        t.durationUnits = v == 1 ? d.getUint64(cs + 24) : d.getUint32(cs + 16);
      case 'hdlr':
        t.handler = String.fromCharCodes([for (var i = 0; i < 4; i++) d.getUint8(cs + 8 + i)]);
      case 'minf' || 'stbl':
        _parseContainer(d, cs, ce, t);
      case 'stsd':
        _parseStsd(d, cs, ce, t);
      case 'stts':
        _parseStts(d, cs, t);
    }
  }
}

void _parseStsd(ByteData d, int s, int e, Mp4Track t) {
  final entries = _boxes(d, s + 8, e);
  if (entries.isEmpty) return;
  final (type, es, ee) = entries.first;
  t.codec = type;
  if (t.handler == 'vide') {
    t.width = d.getUint16(es + 8 + 16);
    t.height = d.getUint16(es + 8 + 18);
    for (final (ct, cs, _) in _boxes(d, es + 78, ee)) {
      if (ct == 'avcC') {
        t.profileIdc = d.getUint8(cs + 1);
        t.levelIdc = d.getUint8(cs + 3);
      } else if (ct == 'hvcC') {
        t.profileIdc = d.getUint8(cs + 1) & 0x1f;
        t.levelIdc = d.getUint8(cs + 12);
      } else if (ct == 'colr') {
        final kind = String.fromCharCodes([for (var i = 0; i < 4; i++) d.getUint8(cs + i)]);
        if (kind == 'nclx' || kind == 'nclc') {
          t.colourPrimaries = d.getUint16(cs + 4);
          t.transferCharacteristics = d.getUint16(cs + 6);
          t.matrixCoefficients = d.getUint16(cs + 8);
          if (kind == 'nclx') t.fullRange = (d.getUint8(cs + 10) & 0x80) != 0;
        }
      }
    }
  } else if (t.handler == 'soun') {
    t.channels = d.getUint16(es + 8 + 8);
    t.sampleRate = d.getUint32(es + 8 + 16) >> 16;
  }
}

void _parseStts(ByteData d, int s, Mp4Track t) {
  final n = d.getUint32(s + 4);
  final counts = <int>[], deltas = <int>[];
  var total = 0;
  for (var i = 0; i < n; i++) {
    final c = d.getUint32(s + 8 + i * 8), dl = d.getUint32(s + 12 + i * 8);
    counts.add(c);
    deltas.add(dl);
    total += c;
  }
  t.sampleCount = total;
  if (n == 0 || t.handler != 'vide') return;
  // Dominant delta defines the frame rate.
  var best = 0;
  for (var i = 1; i < n; i++) {
    if (counts[i] > counts[best]) best = i;
  }
  final dom = deltas[best];
  // Timescale rounding (e.g. 30 fps in a 1 MHz timescale → 33333/33334)
  // is still constant frame rate: allow ±1 tick (or 0.2%).
  final tol = math.max(1, (dom * 0.002).floor());
  var regTicks = 0, regCount = 0;
  for (var i = 0; i < n; i++) {
    if ((deltas[i] - dom).abs() <= tol) {
      regTicks += deltas[i] * counts[i];
      regCount += counts[i];
    }
  }
  if (t.timescale > 0 && regCount > 0) t.fps = t.timescale * regCount / regTicks;
  // CFR: every delta equal, allowing only the final sample to differ (muxers
  // commonly shorten the last frame).
  var irregular = 0;
  for (var i = 0; i < n; i++) {
    if ((deltas[i] - dom).abs() > tol && !(i == n - 1 && counts[i] == 1)) irregular += counts[i];
  }
  t.constantFrameRate = irregular <= math.max(1, total ~/ 500);
}

/// Guarantees a fast-start layout. If moov sits after mdat, rewrites the file
/// as ftyp → moov → media, shifting every chunk offset (stco/co64) by the moov
/// size. Returns true when the file was rewritten. Safe: writes to a temporary
/// file and only replaces the original after a complete, flushed write.
Future<bool> ensureFastStart(String path) async {
  final file = File(path);
  final raf = await file.open();
  final boxes = <(String, int, int)>[]; // type, offset, size
  Uint8List? moov;
  try {
    final len = await raf.length();
    var pos = 0;
    while (pos + 8 <= len) {
      await raf.setPosition(pos);
      final h = await raf.read(16);
      final bd = ByteData.sublistView(h);
      var size = bd.getUint32(0);
      final type = String.fromCharCodes(h.sublist(4, 8));
      if (size == 1) size = bd.getUint64(8);
      if (size == 0) size = len - pos;
      if (size < 8) throw Mp4FormatException('Bad box size at $pos');
      boxes.add((type, pos, size));
      if (type == 'moov') {
        await raf.setPosition(pos);
        moov = await raf.read(size);
      }
      pos += size;
    }
  } finally {
    await raf.close();
  }
  final mi = boxes.indexWhere((b) => b.$1 == 'moov');
  final di = boxes.indexWhere((b) => b.$1 == 'mdat');
  if (mi < 0 || moov == null) throw Mp4FormatException('No moov box');
  if (di < 0 || mi < di) return false;
  if (moov[0] == 0 && moov[1] == 0 && moov[2] == 0 && moov[3] == 1) {
    throw Mp4FormatException('64-bit moov size not supported');
  }

  final shift = moov.length;
  final d = ByteData.sublistView(moov);
  void patch(int s, int e) {
    for (final (type, cs, ce) in _boxes(d, s, e)) {
      switch (type) {
        case 'trak' || 'mdia' || 'minf' || 'stbl':
          patch(cs, ce);
        case 'stco':
          final n = d.getUint32(cs + 4);
          for (var i = 0; i < n; i++) {
            final o = d.getUint32(cs + 8 + i * 4) + shift;
            if (o > 0xFFFFFFFF) throw Mp4FormatException('Offsets exceed 32-bit range');
            d.setUint32(cs + 8 + i * 4, o);
          }
        case 'co64':
          final n = d.getUint32(cs + 4);
          for (var i = 0; i < n; i++) {
            d.setUint64(cs + 8 + i * 8, d.getUint64(cs + 8 + i * 8) + shift);
          }
      }
    }
  }

  patch(8, moov.length);

  final tmp = File('$path.faststart');
  final src = await file.open();
  final out = await tmp.open(mode: FileMode.write);
  try {
    Future<void> copy(int offset, int size) async {
      await src.setPosition(offset);
      var left = size;
      while (left > 0) {
        final chunk = await src.read(math.min(left, 4 << 20));
        if (chunk.isEmpty) throw Mp4FormatException('Unexpected end of file');
        await out.writeFrom(chunk);
        left -= chunk.length;
      }
    }

    // ftyp (and anything before the first non-ftyp box) keeps its place.
    var k = 0;
    while (k < boxes.length && boxes[k].$1 == 'ftyp') {
      await copy(boxes[k].$2, boxes[k].$3);
      k++;
    }
    await out.writeFrom(moov);
    for (; k < boxes.length; k++) {
      if (k == mi) continue;
      await copy(boxes[k].$2, boxes[k].$3);
    }
    await out.flush();
  } finally {
    await src.close();
    await out.close();
  }
  await tmp.rename(path);
  return true;
}
