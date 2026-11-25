import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../engine/models.dart';
import '../../engine/presets.dart';
import '../../services/history_store.dart';
import '../../services/native_engine.dart';
import '../theme.dart';
import '../widgets.dart';
import 'analyze_screen.dart';
import 'result_screen.dart';
import 'tiktok_direct_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _picking = false;
  final _store = HistoryStore.instance;

  Future<void> _select(Preset preset) async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final uri = await NativeEngine.instance.pickVideo();
      if (uri == null || !mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AnalyzeScreen(uri: uri, initialPreset: preset)));
      if (mounted) setState(() {});
    } on EngineException catch (e) {
      if (mounted) showError(context, e.message);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// Upload a video untouched via TikTok's web uploader.
  Future<void> _direct() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final uri = await NativeEngine.instance.pickVideo();
      if (uri == null || !mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TikTokDirectScreen(path: uri, label: 'Original video')));
    } on EngineException catch (e) {
      if (mounted) showError(context, e.message);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _store.entries;
    return Scaffold(
      body: HDBackground(
        child: SafeArea(
          bottom: false,
          child: CustomScrollView(slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
              sliver: SliverList.list(children: [
                Row(children: [
                  const BrandMark(size: 38),
                  const SizedBox(width: 12),
                  const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('HD CLEAN', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17, letterSpacing: 2)),
                    Text('by Mawar Ikhlas Brand', style: TextStyle(color: HD.muted, fontSize: 11.5)),
                  ]),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), border: Border.all(color: HD.line)),
                    child: const Row(children: [
                      Icon(Icons.lock_rounded, size: 13, color: HD.ok),
                      SizedBox(width: 5),
                      Text('On-device', style: TextStyle(fontSize: 11.5, color: HD.muted, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 44),
                Reveal(
                  child: ShaderMask(
                    shaderCallback: (r) => const LinearGradient(colors: [Colors.white, Color(0xFFBFE9FF)]).createShader(r),
                    child: const Text('Make Every\nVideo Look HD.',
                        style: TextStyle(fontSize: 40, height: 1.08, fontWeight: FontWeight.w900, letterSpacing: -1)),
                  ),
                ),
                const SizedBox(height: 12),
                const Reveal(
                  index: 1,
                  child: Text('Optimize your video before sharing.', style: TextStyle(fontSize: 16.5, color: HD.muted)),
                ),
                const SizedBox(height: 30),
                Reveal(
                  index: 2,
                  child: GradientButton(
                    label: 'SELECT VIDEO',
                    icon: Icons.add_photo_alternate_rounded,
                    busy: _picking,
                    height: 66,
                    onPressed: () => _select(Preset.tiktokHd),
                  ),
                ),
                const SizedBox(height: 14),
                Reveal(
                  index: 3,
                  child: GlassCard(
                    highlight: true,
                    padding: const EdgeInsets.all(16),
                    onTap: _direct,
                    child: const Row(children: [
                      Icon(Icons.cloud_upload_rounded, color: HD.cyan, size: 30),
                      SizedBox(width: 14),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('TikTok HD Direct', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                          SizedBox(height: 3),
                          Text('Upload the original file the way a desktop browser does. The TikTok app never compresses it.',
                              style: TextStyle(color: HD.muted, fontSize: 12.5, height: 1.35)),
                        ]),
                      ),
                      Icon(Icons.chevron_right_rounded, color: HD.muted),
                    ]),
                  ),
                ),
                const SizedBox(height: 30),
                const SectionTitle('Optimize for'),
                Reveal(
                  index: 3,
                  child: GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.45,
                    children: [
                      _Feature(Icons.music_note_rounded, 'TikTok HD', '1080p · up to 60 FPS', () => _select(Preset.tiktokHd)),
                      _Feature(Icons.camera_alt_rounded, 'Instagram HD', 'Reels 1080×1920', () => _select(Preset.instagram)),
                      _Feature(Icons.chat_rounded, 'WhatsApp HD', 'Status-ready parts', () => _select(Preset.whatsapp)),
                      _Feature(Icons.tune_rounded, 'Custom HD', 'Your own settings', () => _select(Preset.custom)),
                    ],
                  ),
                ),
                const SizedBox(height: 30),
                SectionTitle('Recent videos', trailing: items.isEmpty ? null : Text('${items.length}', style: kTitle)),
              ]),
            ),
            if (items.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(22, 0, 22, 40),
                  child: GlassCard(
                    child: Row(children: [
                      Icon(Icons.video_library_outlined, color: HD.faint, size: 30),
                      SizedBox(width: 14),
                      Expanded(
                        child: Text('Your optimized videos appear here. Originals are never changed.',
                            style: TextStyle(color: HD.muted, height: 1.4)),
                      ),
                    ]),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 40),
                sliver: SliverList.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (_, i) => _HistoryCard(
                    entry: items[i],
                    onOpen: () async {
                      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ResultScreen.fromHistory(items[i])));
                      if (mounted) setState(() {});
                    },
                    onDelete: () async {
                      await _store.remove(items[i]);
                      if (mounted) setState(() {});
                    },
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature(this.icon, this.title, this.sub, this.onTap);
  final IconData icon;
  final String title, sub;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GlassCard(
        onTap: onTap,
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: HD.blue.withValues(alpha: 0.16)),
            child: Icon(icon, color: HD.cyan, size: 20),
          ),
          const Spacer(),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
          const SizedBox(height: 2),
          Text(sub, style: const TextStyle(color: HD.muted, fontSize: 12)),
        ]),
      );
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.entry, required this.onOpen, required this.onDelete});
  final HistoryEntry entry;
  final VoidCallback onOpen, onDelete;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final (color, label) = switch (e.status) {
      'done' => (HD.ok, e.remuxOnly ? 'Ready (no re-encode)' : 'Optimized'),
      'processing' => (HD.cyan, 'Processing'),
      'cancelled' => (HD.muted, 'Cancelled'),
      'interrupted' => (HD.warn, 'Interrupted'),
      _ => (HD.bad, 'Failed'),
    };
    return Dismissible(
      key: ValueKey(e.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        decoration: BoxDecoration(color: HD.bad.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(22)),
        child: const Icon(Icons.delete_outline_rounded, color: HD.bad),
      ),
      confirmDismiss: (_) => showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: HD.surface,
          title: const Text('Remove from history?'),
          content: const Text('This deletes HD CLEAN\'s optimized copy. Your original video and any copy saved to the gallery are not affected.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove', style: TextStyle(color: HD.bad))),
          ],
        ),
      ),
      onDismissed: (_) => onDelete(),
      child: GlassCard(
        padding: const EdgeInsets.all(12),
        onTap: e.status == 'done' && e.outputs.isNotEmpty ? onOpen : null,
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: 64,
              height: 84,
              child: e.thumbPath != null && File(e.thumbPath!).existsSync()
                  ? Image.file(File(e.thumbPath!), fit: BoxFit.cover)
                  : Container(color: HD.surface, child: const Icon(Icons.movie_outlined, color: HD.faint)),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(e.presetTitle, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
                  child: Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
                ),
              ]),
              const SizedBox(height: 8),
              _line('Original', '${e.source.displayWidth}×${e.source.displayHeight}', formatBytes(e.source.sizeBytes)),
              const SizedBox(height: 3),
              _line(
                'Optimized',
                e.outWidth != null ? '${e.outWidth}×${e.outHeight}' : '—',
                e.status == 'done' ? '${formatBytes(e.outputBytes)}${e.outputs.length > 1 ? ' · ${e.outputs.length} parts' : ''}' : '—',
                accent: true,
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _line(String k, String res, String size, {bool accent = false}) => Row(children: [
        SizedBox(width: 72, child: Text(k, style: const TextStyle(color: HD.muted, fontSize: 12))),
        Text(res, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: accent ? HD.cyan : HD.text)),
        const Text('  ·  ', style: TextStyle(color: HD.faint, fontSize: 12)),
        Flexible(child: Text(size, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
      ]);
}
