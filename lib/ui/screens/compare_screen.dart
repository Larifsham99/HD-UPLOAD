import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../engine/models.dart';
import '../../engine/mp4_inspector.dart';
import '../../services/native_engine.dart';
import '../theme.dart';
import '../widgets.dart';

/// Frame-accurate before/after comparison. Both images are real decoded
/// frames at the same timestamp, one from the original and one from the
/// exported file. No quality percentage is shown, because none can be honestly
/// computed without a reference metric.
class CompareScreen extends StatefulWidget {
  const CompareScreen({
    super.key,
    required this.source,
    required this.outputPath,
    required this.outputSize,
    required this.report,
    required this.partStartMs,
    this.frameMode = 'keep',
  });
  final VideoInfo source;
  final String outputPath;
  final int outputSize;
  final Mp4Report? report;
  final int partStartMs;

  /// keep | fit | fill — how the original maps onto the output frame.
  final String frameMode;
  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  double _split = 0.5;
  double _t = 0.3;
  Uint8List? _before, _after;
  bool _loading = false;
  int _req = 0;

  int get _outDurationMs => widget.report?.durationMs ?? widget.source.durationMs;

  @override
  void initState() {
    super.initState();
    _grab();
  }

  Future<void> _grab() async {
    final id = ++_req;
    setState(() => _loading = true);
    final outMs = (_outDurationMs * _t).round();
    final e = NativeEngine.instance;
    try {
      final results = await Future.wait([
        e.frame(widget.source.uri, timeMs: widget.partStartMs + outMs, maxSize: 1920, exact: true),
        e.frame(widget.outputPath, timeMs: outMs, maxSize: 1920, exact: true),
      ]);
      if (!mounted || id != _req) return;
      setState(() {
        _before = results[0];
        _after = results[1];
      });
    } on EngineException catch (err) {
      if (mounted) showError(context, err.message);
    } finally {
      if (mounted && id == _req) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.source;
    final v = widget.report?.video;
    final outW = v?.width ?? s.displayWidth, outH = v?.height ?? s.displayHeight;
    final outBitrate = _outDurationMs > 0 ? widget.outputSize * 8 * 1000 ~/ _outDurationMs : 0;
    final srcTotal = s.durationMs > 0 ? s.sizeBytes * 8 * 1000 ~/ s.durationMs : 0;
    return Scaffold(
      body: HDBackground(
        child: SafeArea(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 30), children: [
            Row(children: [
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20)),
              const Text('Before & After', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
              const Spacer(),
              if (_loading) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: HD.cyan)),
              const SizedBox(width: 8),
            ]),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: AspectRatio(
                aspectRatio: outW / outH,
                child: LayoutBuilder(builder: (context, c) {
                  final w = c.maxWidth;
                  return GestureDetector(
                    onHorizontalDragUpdate: (d) => setState(() => _split = (d.localPosition.dx / w).clamp(0.0, 1.0)),
                    onTapDown: (d) => setState(() => _split = (d.localPosition.dx / w).clamp(0.0, 1.0)),
                    child: InteractiveViewer(
                      maxScale: 6,
                      panEnabled: false,
                      child: Stack(fit: StackFit.expand, children: [
                        Container(color: Colors.black),
                        if (_after != null) Image.memory(_after!, fit: BoxFit.fill, gaplessPlayback: true, filterQuality: FilterQuality.none),
                        if (_before != null)
                          ClipRect(
                            clipper: _LeftClip(_split),
                            child: Image.memory(_before!,
                                fit: widget.frameMode == 'fill' ? BoxFit.cover : BoxFit.contain,
                                gaplessPlayback: true,
                                filterQuality: FilterQuality.none),
                          ),
                        Positioned(
                          left: w * _split - 1,
                          top: 0,
                          bottom: 0,
                          child: Container(width: 2, color: Colors.white),
                        ),
                        Positioned(
                          left: w * _split - 18,
                          top: c.maxHeight / 2 - 18,
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(shape: BoxShape.circle, gradient: HD.accent, boxShadow: [BoxShadow(color: HD.cyan.withValues(alpha: 0.5), blurRadius: 12)]),
                            child: const Icon(Icons.code_rounded, size: 20, color: Colors.white),
                          ),
                        ),
                        Positioned(left: 10, top: 10, child: _tag('ORIGINAL')),
                        Positioned(right: 10, top: 10, child: _tag('HD CLEAN')),
                      ]),
                    ),
                  );
                }),
              ),
            ),
            const SizedBox(height: 6),
            const Text('Drag to compare · pinch to zoom in on detail', textAlign: TextAlign.center, style: TextStyle(color: HD.faint, fontSize: 12)),
            const SizedBox(height: 12),
            Row(children: [
              const Icon(Icons.schedule_rounded, size: 16, color: HD.muted),
              Expanded(
                child: Slider(
                  value: _t,
                  onChanged: (x) => setState(() => _t = x),
                  onChangeEnd: (_) => _grab(),
                ),
              ),
              Text(formatDuration((_outDurationMs * _t).round()), style: const TextStyle(color: HD.muted, fontFeatures: [FontFeature.tabularFigures()])),
            ]),
            const SizedBox(height: 10),
            GlassCard(
              child: Table(
                columnWidths: const {0: FlexColumnWidth(1.2), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1)},
                children: [
                  _row('', 'Original', 'Optimized', header: true),
                  _row('Resolution', '${s.displayWidth}×${s.displayHeight}', '$outW×$outH'),
                  _row('File size', formatBytes(s.sizeBytes), formatBytes(widget.outputSize)),
                  _row('Bitrate', formatBitrate(srcTotal), formatBitrate(outBitrate)),
                  _row('Format', codecLabel(s.videoCodec), v?.codec != null ? codecLabel(normaliseVideoCodec(v!.codec)) : '—'),
                  _row('Profile', s.videoProfile ?? '—', v?.profileName ?? '—'),
                  _row('Frame rate', '${formatFps(s.fps)}${s.isVfr ? ' VFR' : ''}', v?.fps != null ? '${formatFps(v!.fps!)}${v.constantFrameRate == true ? ' CFR' : ''}' : '—'),
                  _row('Colour', s.isHdr ? '${s.hdr}' : 'SDR', v == null ? '—' : (v.isHdrTransfer ? 'HDR' : 'SDR BT.709')),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Bitrate alone does not measure quality. Use the slider and zoom to judge detail, skin tones and colour with your own eyes.',
              style: TextStyle(color: HD.faint, fontSize: 12, height: 1.4),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _tag(String t) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
        child: Text(t, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 1)),
      );

  TableRow _row(String k, String a, String b, {bool header = false}) {
    final st = TextStyle(
      fontSize: 12.5,
      fontWeight: header ? FontWeight.w800 : FontWeight.w600,
      color: header ? HD.muted : HD.text,
    );
    return TableRow(children: [
      Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(k, style: const TextStyle(color: HD.muted, fontSize: 12.5))),
      Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(a, style: st)),
      Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(b, style: st.copyWith(color: header ? HD.cyan : HD.text))),
    ]);
  }
}

class _LeftClip extends CustomClipper<Rect> {
  _LeftClip(this.f);
  final double f;
  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * f, size.height);
  @override
  bool shouldReclip(_LeftClip o) => o.f != f;
}
