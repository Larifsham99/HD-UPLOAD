// TikTok HD Direct: uploads through TikTok's own *web* uploader (TikTok
// Studio, desktop mode) instead of the TikTok app.
//
// Why: the TikTok mobile app re-compresses videos on the phone before
// uploading. The web uploader sends the file itself to TikTok's servers, which
// is why uploads from a desktop browser (e.g. Microsoft Edge) keep more
// detail and frame rate. On Android, HD CLEAN hands the file straight to the
// page's file picker. On iOS the file is placed in Files → On My iPhone →
// HD CLEAN for "Choose File".
//
// Sign-in happens on tiktok.com itself. HD CLEAN never reads or stores
// credentials; only the web view's normal cookies are kept.

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../engine/models.dart';
import '../../services/native_engine.dart';
import '../theme.dart';
import '../widgets.dart';

const tiktokStudioUploadUrl = 'https://www.tiktok.com/tiktokstudio/upload?from=upload&lang=en';

/// A current desktop Edge user agent so TikTok serves its desktop uploader.
const desktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/142.0.0.0 Safari/537.36 Edg/142.0.0.0';

class TikTokDirectScreen extends StatefulWidget {
  const TikTokDirectScreen({super.key, required this.path, required this.label, this.sizeBytes});

  /// Local file path or (Android) content:// URI of the video to upload.
  final String path;
  final String label;
  final int? sizeBytes;

  @override
  State<TikTokDirectScreen> createState() => _TikTokDirectScreenState();
}

class _TikTokDirectScreenState extends State<TikTokDirectScreen> {
  late final WebViewController _web;
  int _progress = 0;
  bool _guide = true;
  String? _uploadUri;
  String? _filesPath;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prepareFile();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(desktopUserAgent)
      ..setBackgroundColor(HD.bg)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) => mounted ? setState(() => _progress = p) : null,
        onPageFinished: (_) => _desktopViewport(),
        onWebResourceError: (e) {
          if (e.isForMainFrame == true && mounted) {
            setState(() => _error = 'Could not load TikTok (${e.description}). Check your internet connection.');
          }
        },
        // Keep TikTok inside this desktop uploader: never jump to the TikTok
        // app (which would re-compress the video).
        onNavigationRequest: (r) =>
            r.url.startsWith('http://') || r.url.startsWith('https://') || r.url.startsWith('about:') || r.url.startsWith('blob:')
                ? NavigationDecision.navigate
                : NavigationDecision.prevent,
      ));
    final platform = _web.platform;
    if (platform is AndroidWebViewController) {
      platform
        ..setUseWideViewPort(true)
        ..enableZoom(true)
        ..setMediaPlaybackRequiresUserGesture(true)
        ..setOnShowFileSelector(_onFileSelector);
      AndroidWebViewCookieManager(const PlatformWebViewCookieManagerCreationParams())
          .setAcceptThirdPartyCookies(platform, true);
    }
    _web.loadRequest(Uri.parse(tiktokStudioUploadUrl));
  }

  Future<void> _prepareFile() async {
    try {
      if (Platform.isAndroid) {
        _uploadUri = await NativeEngine.instance.contentUri(widget.path);
      } else {
        _filesPath = await NativeEngine.instance.copyToFiles(widget.path);
      }
      if (mounted) setState(() {});
    } on EngineException catch (e) {
      if (mounted) showError(context, e.message);
    }
  }

  /// Render TikTok Studio at desktop width; the user can pinch-zoom.
  Future<void> _desktopViewport() async {
    try {
      await _web.runJavaScript('''
        (function(){
          var m = document.querySelector('meta[name=viewport]');
          if (!m) { m = document.createElement('meta'); m.name = 'viewport'; document.head.appendChild(m); }
          m.content = 'width=1280, initial-scale=' + (screen.width / 1280) + ', user-scalable=yes';
        })();
      ''');
    } catch (_) {}
  }

  /// Android: TikTok's "Select video" opens this instead of a system picker,
  /// and receives HD CLEAN's file unchanged.
  Future<List<String>> _onFileSelector(FileSelectorParams params) async {
    final uri = _uploadUri;
    if (uri == null) return const [];
    if (mounted) showInfo(context, '${widget.label} attached — uploading the original file to TikTok.');
    return [uri];
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _web.canGoBack()) {
          await _web.goBack();
        } else if (context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        backgroundColor: HD.bg,
        body: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
              child: Row(children: [
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
                const BrandMark(size: 26),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('TikTok HD Direct', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                    Text('Web upload · no TikTok-app compression', style: TextStyle(color: HD.muted, fontSize: 11.5)),
                  ]),
                ),
                IconButton(
                  tooltip: 'How it works',
                  onPressed: () => setState(() => _guide = !_guide),
                  icon: Icon(_guide ? Icons.expand_less_rounded : Icons.help_outline_rounded),
                ),
                IconButton(tooltip: 'Reload', onPressed: () => _web.reload(), icon: const Icon(Icons.refresh_rounded)),
              ]),
            ),
            if (_progress < 100) LinearProgressIndicator(value: _progress / 100, minHeight: 2, color: HD.cyan, backgroundColor: HD.line),
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              child: _guide ? _guideCard() : const SizedBox(width: double.infinity),
            ),
            Expanded(
              child: _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.wifi_off_rounded, color: HD.warn, size: 40),
                          const SizedBox(height: 12),
                          Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: HD.muted)),
                          const SizedBox(height: 16),
                          SecondaryButton(
                            label: 'Try again',
                            onPressed: () {
                              setState(() => _error = null);
                              _web.loadRequest(Uri.parse(tiktokStudioUploadUrl));
                            },
                          ),
                        ]),
                      ),
                    )
                  : WebViewWidget(controller: _web),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _guideCard() {
    final android = Platform.isAndroid;
    final steps = [
      'Log in to TikTok on this page (first time only). Your login stays on tiktok.com.',
      android
          ? 'Tap "Select video". HD CLEAN attaches ${widget.label} automatically.'
          : 'Tap "Select video" → Choose File → On My iPhone → HD CLEAN → ${_filesPath?.split('/').last ?? widget.label}.',
      'Add your caption and tap Post. Stay on this screen until the upload reaches 100%.',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.movie_filter_rounded, color: HD.cyan, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${widget.label}${widget.sizeBytes != null ? ' · ${formatBytes(widget.sizeBytes!)}' : ''}',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            ),
          ]),
          const SizedBox(height: 8),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 18,
                  height: 18,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(shape: BoxShape.circle, gradient: HD.accent),
                  child: Text('${i + 1}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.white)),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(steps[i], style: const TextStyle(color: HD.muted, fontSize: 12.5, height: 1.35))),
              ]),
            ),
          Row(children: [
            const Expanded(
              child: Text('If login inside the app is blocked, open TikTok Studio in your browser with "Desktop site" turned on.',
                  style: TextStyle(color: HD.faint, fontSize: 11.5, height: 1.35)),
            ),
            TextButton(
              onPressed: () => NativeEngine.instance.openExternal(tiktokStudioUploadUrl),
              child: const Text('Open browser'),
            ),
          ]),
        ]),
      ),
    );
  }
}
