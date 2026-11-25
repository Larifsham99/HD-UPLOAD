// Export presets. Bitrate numbers are the *upload source* targets for each
// platform: high enough that the platform's own re-encode starts from a
// clean master, without wasting upload time on bits the platform discards.

enum PresetId { tiktokHd, tiktok4k, instagram, whatsapp, custom }

class BitrateRange {
  const BitrateRange(this.min, this.max, this.small);

  /// Lower and upper bound for Balanced/Maximum, in bits per second.
  final int min;
  final int max;

  /// Target used by "Smaller File" mode.
  final int small;
}

class Preset {
  const Preset({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.platform,
    required this.shortEdge,
    required this.longEdge,
    required this.maxFps,
    required this.rate30,
    required this.rate60,
    this.allowHevc = false,
    this.defaultFrameMode916 = false,
    this.audioBitrate = 256000,
    this.statusSegmentSec,
  });

  final PresetId id;
  final String title;
  final String subtitle;
  final String platform;
  final int shortEdge;
  final int longEdge;
  final double maxFps;

  /// H.264 bitrate range for output at [shortEdge]x[longEdge], ≤30 fps.
  final BitrateRange rate30;

  /// H.264 bitrate range for output at [shortEdge]x[longEdge], >30 fps.
  final BitrateRange rate60;
  final bool allowHevc;
  final bool defaultFrameMode916;
  final int audioBitrate;

  /// WhatsApp Status style limit: long videos are split into parts.
  final int? statusSegmentSec;

  static const _mbps = 1000000;

  static const tiktokHd = Preset(
    id: PresetId.tiktokHd,
    title: 'TikTok HD',
    subtitle: '1080×1920 · H.264 · 12–20 Mbps',
    platform: 'TikTok',
    shortEdge: 1080,
    longEdge: 1920,
    maxFps: 60,
    rate30: BitrateRange(12 * _mbps, 16 * _mbps, 8 * _mbps),
    rate60: BitrateRange(16 * _mbps, 20 * _mbps, 11 * _mbps),
  );

  static const tiktok4k = Preset(
    id: PresetId.tiktok4k,
    title: 'TikTok 4K',
    subtitle: '2160×3840 · H.264 / HEVC',
    platform: 'TikTok',
    shortEdge: 2160,
    longEdge: 3840,
    maxFps: 60,
    rate30: BitrateRange(35 * _mbps, 45 * _mbps, 24 * _mbps),
    rate60: BitrateRange(45 * _mbps, 60 * _mbps, 32 * _mbps),
    allowHevc: true,
  );

  static const instagram = Preset(
    id: PresetId.instagram,
    title: 'Instagram HD',
    subtitle: 'Reels · 1080×1920 · H.264 · AAC',
    platform: 'Instagram',
    shortEdge: 1080,
    longEdge: 1920,
    maxFps: 60,
    rate30: BitrateRange(10 * _mbps, 14 * _mbps, 7 * _mbps),
    rate60: BitrateRange(13 * _mbps, 18 * _mbps, 9 * _mbps),
  );

  static const whatsapp = Preset(
    id: PresetId.whatsapp,
    title: 'WhatsApp HD',
    subtitle: 'Status · 1080×1920 · practical size',
    platform: 'WhatsApp',
    shortEdge: 1080,
    longEdge: 1920,
    maxFps: 30,
    rate30: BitrateRange(5 * _mbps, 8 * _mbps, 3500000),
    rate60: BitrateRange(5 * _mbps, 8 * _mbps, 3500000),
    audioBitrate: 192000,
    statusSegmentSec: 60,
  );

  /// Custom uses TikTok-HD style ranges as the starting point.
  static const custom = Preset(
    id: PresetId.custom,
    title: 'Custom HD',
    subtitle: 'Your resolution, FPS, bitrate, codec',
    platform: 'Any',
    shortEdge: 1080,
    longEdge: 1920,
    maxFps: 60,
    rate30: BitrateRange(12 * _mbps, 16 * _mbps, 8 * _mbps),
    rate60: BitrateRange(16 * _mbps, 20 * _mbps, 11 * _mbps),
    allowHevc: true,
  );

  static const all = [tiktokHd, tiktok4k, instagram, whatsapp, custom];

  static Preset byId(PresetId id) => all.firstWhere((p) => p.id == id);
}
