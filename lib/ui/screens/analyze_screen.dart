import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../engine/models.dart';
import '../../engine/planner.dart';
import '../../engine/presets.dart';
import '../../engine/upload_doctor.dart';
import '../../services/native_engine.dart';
import '../theme.dart';
import '../widgets.dart';
import 'processing_screen.dart';

String aspectLabel(int w, int h) {
  final r = w / h;
  const known = {'9:16': 9 / 16, '16:9': 16 / 9, '3:4': 3 / 4, '4:3': 4 / 3, '1:1': 1.0, '4:5': 4 / 5, '21:9': 21 / 9, '9:19.5': 9 / 19.5, '2:3': 2 / 3, '3:2': 3 / 2};
  for (final e in known.entries) {
    if ((r - e.value).abs() / e.value < 0.012) return e.key;
  }
  return r >= 1 ? '${r.toStringAsFixed(2)}:1' : '1:${(1 / r).toStringAsFixed(2)}';
}

class AnalyzeScreen extends StatefulWidget {
  const AnalyzeScreen({super.key, required this.uri, required this.initialPreset});
  final String uri;
  final Preset initialPreset;
  @override
  State<AnalyzeScreen> createState() => _AnalyzeScreenState();
}

class _AnalyzeScreenState extends State<AnalyzeScreen> {
  VideoInfo? _info;
  Uint8List? _thumb;
  String? _error;
  late PlanOptions _opts = PlanOptions(preset: widget.initialPreset);
  bool _showAllFindings = false;

  @override
  void initState() {
    super.initState();
    _analyze();
  }

  Future<void> _analyze() async {
    try {
      final engine = NativeEngine.instance;
      final info = await engine.probe(widget.uri);
      Uint8List? thumb;
      try {
        thumb = await engine.frame(widget.uri, timeMs: (info.durationMs * 0.2).round().clamp(0, 3000), maxSize: 720);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _info = info;
        _thumb = thumb;
        if (_opts.preset.id == PresetId.tiktok4k && info.shortSide < 2000) _opts = _opts.copyWith(preset: Preset.tiktokHd);
      });
    } on EngineException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  ({PlanResult? result, String? error}) _plan() {
    try {
      return (result: planEncode(_info!, _opts), error: null);
    } on PlannerException catch (e) {
      return (result: null, error: e.message);
    }
  }

  void _start(PlanResult r) {
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => ProcessingScreen(source: _info!, result: r, preset: _opts.preset, quality: _opts.quality, thumbnail: _thumb),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: HDBackground(
        child: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
              child: Row(children: [
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20)),
                const Text('Smart Analyzer', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
              ]),
            ),
            Expanded(child: _body()),
          ]),
        ),
      ),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline_rounded, color: HD.bad, size: 48),
            const SizedBox(height: 14),
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: HD.muted, height: 1.4)),
            const SizedBox(height: 22),
            SecondaryButton(label: 'Choose another video', onPressed: () => Navigator.pop(context)),
          ]),
        ),
      );
    }
    final s = _info;
    if (s == null) {
      return const Center(
        child: ProgressRing(
          value: 0,
          indeterminate: true,
          size: 170,
          child: Text('Analyzing…', style: TextStyle(color: HD.muted, fontWeight: FontWeight.w600)),
        ),
      );
    }
    final plan = _plan();
    final findings = diagnose(s, _opts.preset);
    final assess = assessSource(s);
    final visibleFindings = _showAllFindings ? findings : findings.take(4).toList();

    return ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 36), children: [
      Reveal(child: _hero(s)),
      const SizedBox(height: 18),
      Reveal(
        index: 1,
        child: GlassCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('ORIGINAL VIDEO', style: kTitle),
            const SizedBox(height: 16),
            StatGrid([
              ('Resolution', '${s.displayWidth} × ${s.displayHeight}'),
              ('Aspect ratio', aspectLabel(s.displayWidth, s.displayHeight)),
              ('Frame rate', '${formatFps(s.fps)}${s.isVfr ? ' · VFR' : ' · CFR'}'),
              ('Bitrate', formatBitrate(s.effectiveVideoBitrate)),
              ('Format', codecLabel(s.videoCodec)),
              ('Dynamic range', s.isHdr ? '${s.hdr} HDR' : 'SDR${s.bitDepth > 8 ? ' ${s.bitDepth}-bit' : ''}'),
              ('Audio', s.hasAudio ? '${codecLabel(s.audioCodec ?? 'other')} ${s.audioSampleRate != null ? '${(s.audioSampleRate! / 1000).toStringAsFixed(s.audioSampleRate! % 1000 == 0 ? 0 : 1)} kHz' : ''}' : 'None'),
              ('File size', formatBytes(s.sizeBytes)),
              ('Duration', formatDuration(s.durationMs)),
              ('Orientation', s.isPortrait ? 'Portrait' : 'Landscape'),
            ]),
          ]),
        ),
      ),
      const SizedBox(height: 14),
      Reveal(
        index: 2,
        child: GlassCard(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _gradeBadge(assess.grade),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Source quality: ${assess.grade}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                const SizedBox(height: 4),
                Text(assess.summary, style: const TextStyle(color: HD.muted, height: 1.4, fontSize: 13)),
              ]),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 24),
      SectionTitle('Upload Doctor · ${_opts.preset.platform}',
          trailing: findings.length > 4
              ? GestureDetector(
                  onTap: () => setState(() => _showAllFindings = !_showAllFindings),
                  child: Text(_showAllFindings ? 'LESS' : 'ALL ${findings.length}', style: kTitle.copyWith(color: HD.cyan)),
                )
              : null),
      GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 250),
          child: Column(children: [
            for (var i = 0; i < visibleFindings.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: HD.line),
              _FindingTile(visibleFindings[i]),
            ],
          ]),
        ),
      ),
      const SizedBox(height: 24),
      const SectionTitle('Export preset'),
      SizedBox(
        height: 44,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final p in Preset.all)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _Chip(
                label: p.title,
                selected: _opts.preset.id == p.id,
                enabled: p.id != PresetId.tiktok4k || s.shortSide >= 2000,
                onTap: () => setState(() => _opts = _opts.copyWith(preset: p)),
              ),
            ),
        ]),
      ),
      if (s.shortSide < 2000 && _opts.preset.id == PresetId.tiktokHd)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('TikTok 4K needs a 4K source — never faked by upscaling.', style: TextStyle(color: HD.faint, fontSize: 12)),
        ),
      const SizedBox(height: 18),
      const SectionTitle('Compression'),
      Segmented<QualityMode>(
        values: QualityMode.values,
        selected: _opts.quality,
        label: (q) => q.label,
        onChanged: (q) => setState(() => _opts = _opts.copyWith(quality: q)),
      ),
      const SizedBox(height: 18),
      const SectionTitle('Framing'),
      Segmented<FrameMode>(
        values: FrameMode.values,
        selected: _opts.frameMode,
        label: (m) => switch (m) { FrameMode.keep => 'Keep original', FrameMode.fit => 'Fit 9:16', FrameMode.fill => 'Fill 9:16' },
        onChanged: (m) => setState(() => _opts = _opts.copyWith(frameMode: m)),
      ),
      const SizedBox(height: 12),
      if (_opts.preset.allowHevc && _opts.preset.id != PresetId.custom) _codecRow(),
      if (_opts.preset.id == PresetId.custom) _customControls(s),
      if (s.shortSide < 1000)
        _toggle('Export at 1080p upload tier', 'Platforms may treat 1080p uploads with a higher bitrate. This does not add detail.',
            _opts.allowUpscaleTo1080, (v) => _opts = _opts.copyWith(allowUpscaleTo1080: v)),
      if (_opts.preset.statusSegmentSec != null && s.durationMs > 60500) _splitControls(),
      _toggle('Force re-encode', 'Re-encode even when the source is already an optimal upload master.', _opts.forceReencode,
          (v) => _opts = _opts.copyWith(forceReencode: v)),
      const SizedBox(height: 18),
      const SectionTitle('Export plan'),
      if (plan.error != null)
        GlassCard(child: Text(plan.error!, style: const TextStyle(color: HD.warn, height: 1.4)))
      else
        _planCard(plan.result!),
      const SizedBox(height: 24),
      GradientButton(
        label: plan.result?.alreadyOptimized == true ? 'PREPARE FOR UPLOAD' : 'OPTIMIZE HD',
        icon: Icons.auto_awesome_rounded,
        onPressed: plan.result == null ? null : () => _start(plan.result!),
      ),
      const SizedBox(height: 10),
      const Center(
        child: Text('Processed on this device. Your original is never modified.', style: TextStyle(color: HD.faint, fontSize: 12)),
      ),
    ]);
  }

  Widget _hero(VideoInfo s) => ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: AspectRatio(
          aspectRatio: 16 / 10,
          child: Stack(fit: StackFit.expand, children: [
            Container(color: HD.surface),
            if (_thumb != null) Image.memory(_thumb!, fit: BoxFit.contain, gaplessPlayback: true),
            Positioned(
              left: 14,
              bottom: 14,
              child: Row(children: [
                _badge(s.resolutionLabel, HD.blue),
                const SizedBox(width: 6),
                _badge(formatDuration(s.durationMs), Colors.black54),
                if (s.isHdr) ...[const SizedBox(width: 6), _badge(s.hdr!, HD.violet)],
              ]),
            ),
          ]),
        ),
      );

  Widget _badge(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(8)),
        child: Text(t, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.white)),
      );

  Widget _gradeBadge(String grade) {
    final c = switch (grade) { 'Excellent' => HD.ok, 'Good' => HD.cyan, 'Fair' => HD.warn, _ => HD.bad };
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(shape: BoxShape.circle, color: c.withValues(alpha: 0.15), border: Border.all(color: c.withValues(alpha: 0.6))),
      child: Icon(grade == 'Excellent' || grade == 'Good' ? Icons.verified_rounded : Icons.info_outline_rounded, color: c),
    );
  }

  Widget _toggle(String title, String sub, bool value, void Function(bool) set) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(sub, style: const TextStyle(color: HD.muted, fontSize: 12, height: 1.35)),
            ]),
          ),
          Switch(value: value, onChanged: (v) => setState(() => set(v))),
        ]),
      );

  Widget _codecRow() => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Segmented<String>(
          values: const ['h264', 'hevc'],
          selected: _opts.codec,
          label: (c) => c == 'h264' ? 'H.264 (most compatible)' : 'HEVC (smaller)',
          onChanged: (c) => setState(() => _opts = _opts.copyWith(codec: c)),
        ),
      );

  Widget _splitControls() => Column(children: [
        _toggle('Split for Status', 'Cut into equal parts so WhatsApp does not trim or re-cut it.', _opts.splitForStatus,
            (v) => _opts = _opts.copyWith(splitForStatus: v)),
        if (_opts.splitForStatus)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Segmented<int>(
              values: const [30, 60, 90],
              selected: _opts.statusSegmentSec ?? 60,
              label: (v) => '$v s parts',
              onChanged: (v) => setState(() => _opts = _opts.copyWith(statusSegmentSec: v)),
            ),
          ),
      ]);

  Widget _customControls(VideoInfo s) {
    Widget label(String t) => Padding(padding: const EdgeInsets.only(top: 12, bottom: 8), child: Text(t, style: const TextStyle(color: HD.muted, fontSize: 12.5, fontWeight: FontWeight.w600)));
    final bitrate = _opts.customBitrate;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      label('Resolution (short edge)'),
      Segmented<int>(
        values: const [0, 720, 1080, 1440, 2160],
        selected: _opts.customShortEdge ?? 0,
        label: (v) => v == 0 ? 'Auto' : '${v}p',
        onChanged: (v) => setState(() => _opts = _opts.copyWith(customShortEdge: () => v == 0 ? null : v)),
      ),
      label('Frame rate'),
      Segmented<double>(
        values: const [0, 24, 25, 30, 50, 60],
        selected: _opts.customFps ?? 0,
        label: (v) => v == 0 ? 'Source' : v.toInt().toString(),
        onChanged: (v) => setState(() => _opts = _opts.copyWith(customFps: () => v == 0 ? null : v)),
      ),
      label('Video codec'),
      Segmented<String>(
        values: const ['h264', 'hevc'],
        selected: _opts.codec,
        label: (c) => c == 'h264' ? 'H.264' : 'HEVC',
        onChanged: (c) => setState(() => _opts = _opts.copyWith(codec: c)),
      ),
      label('Video bitrate: ${bitrate == null ? 'Auto' : formatBitrate(bitrate)}'),
      Row(children: [
        Expanded(
          child: Slider(
            min: 2,
            max: 80,
            divisions: 78,
            value: ((bitrate ?? 0) / 1000000).clamp(2, 80).toDouble(),
            onChanged: (v) => setState(() => _opts = _opts.copyWith(customBitrate: () => (v * 1000000).round())),
          ),
        ),
        TextButton(
          onPressed: bitrate == null ? null : () => setState(() => _opts = _opts.copyWith(customBitrate: () => null)),
          child: const Text('Auto'),
        ),
      ]),
      label('Audio quality'),
      Segmented<int>(
        values: const [0, 128000, 192000, 256000, 320000],
        selected: _opts.customAudioBitrate ?? 0,
        label: (v) => v == 0 ? 'Auto' : '${v ~/ 1000}k',
        onChanged: (v) => setState(() => _opts = _opts.copyWith(customAudioBitrate: () => v == 0 ? null : v)),
      ),
      const SizedBox(height: 8),
    ]);
  }

  Widget _planCard(PlanResult r) {
    final p = r.plan;
    final s = _info!;
    return GlassCard(
      highlight: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(r.alreadyOptimized ? 'NO RE-ENCODE NEEDED' : 'OPTIMIZED OUTPUT', style: kTitle.copyWith(color: HD.cyan)),
          const Spacer(),
          if (r.parts.length > 1) Text('${r.parts.length} PARTS', style: kTitle.copyWith(color: HD.cyan)),
        ]),
        const SizedBox(height: 16),
        StatGrid([
          ('Resolution', r.alreadyOptimized ? '${s.displayWidth} × ${s.displayHeight}' : '${p.width} × ${p.height}'),
          ('Frame rate', '${formatFps(p.fps)} CFR'),
          ('Codec', r.alreadyOptimized ? '${codecLabel(s.videoCodec)} (kept)' : '${codecLabel(p.videoCodec)} ${p.videoCodec == 'h264' ? 'High' : 'Main'}'),
          ('Video bitrate', r.alreadyOptimized ? formatBitrate(s.effectiveVideoBitrate) : formatBitrate(p.videoBitrate)),
          ('Audio', switch (p.audioMode) { 'none' => 'None', 'copy' => 'Original AAC (kept)', _ => 'AAC-LC ${p.audioBitrate ~/ 1000}k · 48 kHz' }),
          ('Estimated size', '≈ ${formatBytes(r.estimatedBytes)}'),
        ]),
        const SizedBox(height: 16),
        const Divider(height: 1, color: HD.line),
        const SizedBox(height: 12),
        for (final d in r.decisions)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.check_rounded, size: 15, color: HD.cyan)),
              const SizedBox(width: 8),
              Expanded(child: Text(d, style: const TextStyle(color: HD.muted, fontSize: 12.5, height: 1.4))),
            ]),
          ),
      ]),
    );
  }
}

class _FindingTile extends StatelessWidget {
  const _FindingTile(this.f);
  final Finding f;
  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (f.severity) {
      Severity.critical => (Icons.report_rounded, HD.bad),
      Severity.warning => (Icons.warning_amber_rounded, HD.warn),
      Severity.info => (Icons.info_outline_rounded, HD.cyan),
      Severity.ok => (Icons.check_circle_outline_rounded, HD.ok),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(f.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            const SizedBox(height: 3),
            Text(f.detail, style: const TextStyle(color: HD.muted, fontSize: 12.5, height: 1.4)),
            if (f.fix != null) ...[
              const SizedBox(height: 5),
              Text('HD CLEAN: ${f.fix}', style: const TextStyle(color: HD.cyan, fontSize: 12.5, height: 1.4, fontWeight: FontWeight.w600)),
            ],
          ]),
        ),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap, this.enabled = true});
  final String label;
  final bool selected, enabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: enabled ? 1 : 0.35,
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: selected ? HD.accent : null,
              color: selected ? null : HD.glass,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: selected ? Colors.transparent : HD.line),
            ),
            child: Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: selected ? Colors.white : HD.muted)),
          ),
        ),
      );
}
