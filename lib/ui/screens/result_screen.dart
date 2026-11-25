import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../../engine/models.dart';
import '../../engine/mp4_inspector.dart';
import '../../engine/presets.dart';
import '../../engine/upload_doctor.dart';
import '../../services/history_store.dart';
import '../../services/job_runner.dart';
import '../../services/native_engine.dart';
import '../theme.dart';
import '../widgets.dart';
import 'compare_screen.dart';

class ResultScreen extends StatefulWidget {
  const ResultScreen({super.key, required this.entry, required this.verified, required this.preset});

  factory ResultScreen.fromHistory(HistoryEntry e) => ResultScreen(
        entry: e,
        verified: e.outputs.map((o) => VerifiedOutput(o, null)).toList(),
        preset: Preset.all.firstWhere((p) => p.title == e.presetTitle, orElse: () => Preset.custom),
      );

  final HistoryEntry entry;
  final List<VerifiedOutput> verified;
  final Preset preset;
  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  int _part = 0;
  VideoPlayerController? _player;
  late List<Mp4Report?> _reports = widget.verified.map((v) => v.report).toList();
  String? _busy;

  OutputFile get _file => widget.verified[_part].file;

  /// Matches the planner's equal split so part N compares against the right
  /// moment of the original.
  int _partStart() {
    final n = widget.verified.length;
    if (n <= 1) return 0;
    return _part * (widget.entry.source.durationMs / n).ceil();
  }

  @override
  void initState() {
    super.initState();
    _load();
    _verifyMissing();
  }

  Future<void> _verifyMissing() async {
    final r = List<Mp4Report?>.from(_reports);
    for (var i = 0; i < r.length; i++) {
      if (r[i] != null) continue;
      try {
        r[i] = await inspectMp4(widget.verified[i].file.path);
      } catch (_) {}
    }
    if (mounted) setState(() => _reports = r);
  }

  Future<void> _load() async {
    final old = _player;
    final c = VideoPlayerController.file(File(_file.path));
    setState(() => _player = null);
    await old?.dispose();
    try {
      await c.initialize();
      await c.setLooping(true);
      await c.play();
      if (mounted) setState(() => _player = c);
    } catch (_) {
      await c.dispose();
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _do(String key, Future<void> Function() f, {String? success}) async {
    if (_busy != null) return;
    setState(() => _busy = key);
    try {
      await f();
      if (mounted && success != null) showInfo(context, success);
    } on EngineException catch (e) {
      if (mounted) showError(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _saveAll() async {
    for (final v in widget.verified) {
      await NativeEngine.instance.saveToGallery(v.file.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final rep = _reports[_part];
    final v = rep?.video;
    final a = rep?.audio;
    final engine = NativeEngine.instance;
    final multi = widget.verified.length > 1;
    return Scaffold(
      body: HDBackground(
        child: SafeArea(
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 6, 20, 36), children: [
            Row(children: [
              IconButton(
                onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
                icon: const Icon(Icons.close_rounded),
              ),
              const Spacer(),
              const BrandMark(size: 28),
            ]),
            Reveal(
              child: Column(children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: HD.accent,
                    boxShadow: [BoxShadow(color: HD.cyan.withValues(alpha: 0.45), blurRadius: 30)],
                  ),
                  child: const Icon(Icons.check_rounded, color: Colors.white, size: 36),
                ),
                const SizedBox(height: 14),
                Text(e.remuxOnly ? 'Ready to Upload' : 'HD Optimized',
                    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
                const SizedBox(height: 4),
                Text('${widget.preset.title} · ${e.qualityLabel}', style: const TextStyle(color: HD.muted)),
              ]),
            ),
            const SizedBox(height: 20),
            if (multi)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Segmented<int>(
                  values: List.generate(widget.verified.length, (i) => i),
                  selected: _part,
                  label: (i) => 'Part ${i + 1}',
                  onChanged: (i) {
                    setState(() => _part = i);
                    _load();
                  },
                ),
              ),
            _preview(),
            const SizedBox(height: 16),
            GlassCard(
              child: StatGrid([
                ('Final size', multi ? '${formatBytes(_file.sizeBytes)} (all: ${formatBytes(e.outputBytes)})' : formatBytes(_file.sizeBytes)),
                ('Resolution', v?.width != null ? '${v!.width} × ${v.height}' : '${e.outWidth ?? '—'} × ${e.outHeight ?? '—'}'),
                ('Frame rate', v?.fps != null ? '${formatFps(v!.fps!)}${v.constantFrameRate == true ? ' CFR' : ''}' : (e.outFps != null ? formatFps(e.outFps!) : '—')),
                ('Codec', v == null ? codecLabel(e.outCodec ?? '') : '${codecLabel(normaliseVideoCodec(v.codec))}${v.profileName != null ? ' ${v.profileName}' : ''}'),
                ('Bitrate', formatBitrate(e.outBitrate ?? 0)),
                ('Processing time', e.processingMs == null ? '—' : '${(e.processingMs! / 1000).toStringAsFixed(1)} s'),
              ]),
            ),
            const SizedBox(height: 14),
            if (rep != null) _verification(rep, v, a),
            const SizedBox(height: 20),
            GradientButton(
              label: multi ? 'SAVE ALL TO GALLERY' : 'SAVE TO GALLERY',
              icon: Icons.download_rounded,
              busy: _busy == 'save',
              onPressed: () => _do('save', _saveAll, success: multi ? 'All ${widget.verified.length} parts saved to your gallery.' : 'Saved to your gallery.'),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: SecondaryButton(label: 'TikTok', icon: Icons.music_note_rounded, onPressed: () => _do('tt', () => engine.share(_file.path, 'tiktok')))),
              const SizedBox(width: 10),
              Expanded(child: SecondaryButton(label: 'Instagram', icon: Icons.camera_alt_rounded, onPressed: () => _do('ig', () => engine.share(_file.path, 'instagram')))),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: SecondaryButton(label: 'WhatsApp', icon: Icons.chat_rounded, onPressed: () => _do('wa', () => engine.share(_file.path, 'whatsapp')))),
              const SizedBox(width: 10),
              Expanded(child: SecondaryButton(label: 'Share video', icon: Icons.ios_share_rounded, onPressed: () => _do('any', () => engine.share(_file.path, 'any')))),
            ]),
            const SizedBox(height: 10),
            SecondaryButton(
              label: 'Compare before & after',
              icon: Icons.compare_rounded,
              color: HD.cyan,
              onPressed: () {
                _player?.pause();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => CompareScreen(source: e.source, outputPath: _file.path, outputSize: _file.sizeBytes, report: rep, partStartMs: _partStart(), frameMode: e.frameMode),
                ));
              },
            ),
            const SizedBox(height: 24),
            SectionTitle('Before you upload to ${widget.preset.platform == 'Any' ? 'any app' : widget.preset.platform}'),
            GlassCard(
              child: Column(children: [
                for (final t in uploadTips(widget.preset))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.tips_and_updates_outlined, size: 16, color: HD.cyan)),
                      const SizedBox(width: 10),
                      Expanded(child: Text(t, style: const TextStyle(color: HD.muted, fontSize: 13, height: 1.4))),
                    ]),
                  ),
              ]),
            ),
            const SizedBox(height: 12),
            const Text(
              'Every platform re-compresses uploads. HD CLEAN cannot stop that; it gives the platform the cleanest, correctly formatted source so the published video keeps as much detail as possible.',
              style: TextStyle(color: HD.faint, fontSize: 12, height: 1.45),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _preview() {
    final p = _player;
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Container(
        color: Colors.black,
        height: 380,
        child: p == null
            ? const Center(child: CircularProgressIndicator(color: HD.cyan))
            : GestureDetector(
                onTap: () => setState(() => p.value.isPlaying ? p.pause() : p.play()),
                child: Stack(alignment: Alignment.center, children: [
                  Center(child: AspectRatio(aspectRatio: p.value.aspectRatio, child: VideoPlayer(p))),
                  if (!p.value.isPlaying)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                      child: const Icon(Icons.play_arrow_rounded, size: 40),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: VideoProgressIndicator(p, allowScrubbing: true, colors: const VideoProgressColors(playedColor: HD.cyan)),
                  ),
                ]),
              ),
      ),
    );
  }

  Widget _verification(Mp4Report r, Mp4Track? v, Mp4Track? a) {
    final checks = <(bool, String)>[
      (r.fastStart, 'Fast-start MP4 (index before media)'),
      if (v != null) (v.width != null && v.width!.isEven && v.height!.isEven, 'Even dimensions ${v.width}×${v.height}'),
      if (v != null && v.codec != null)
        (true, '${codecLabel(normaliseVideoCodec(v.codec))}${v.profileName != null ? ' ${v.profileName}' : ''}${v.levelName != null ? ' @ L${v.levelName}' : ''}'),
      if (v?.constantFrameRate != null) (v!.constantFrameRate!, v.constantFrameRate! ? 'Constant frame rate' : 'Frame timing not constant'),
      if (v != null) (!v.isHdrTransfer && v.isBt709, v.isHdrTransfer ? 'HDR transfer still present' : 'SDR BT.709 colour'),
      if (a != null) (a.sampleRate == 48000, 'Audio ${codecLabel(normaliseAudioCodec(a.codec))} ${a.sampleRate != null ? '${a.sampleRate! ~/ 1000} kHz' : ''} ${a.channels == 2 ? 'stereo' : a.channels == 1 ? 'mono' : ''}'),
    ];
    return GlassCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('VERIFIED OUTPUT FILE', style: kTitle),
        const SizedBox(height: 4),
        const Text('Read back from the exported MP4, not assumed from settings.', style: TextStyle(color: HD.faint, fontSize: 12)),
        const SizedBox(height: 10),
        for (final (ok, label) in checks)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Icon(ok ? Icons.verified_rounded : Icons.error_outline_rounded, size: 17, color: ok ? HD.ok : HD.warn),
              const SizedBox(width: 10),
              Expanded(child: Text(label, style: const TextStyle(fontSize: 13.5))),
            ]),
          ),
      ]),
    );
  }
}
