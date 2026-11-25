# HD CLEAN

**Premium HD video optimizer for iOS & Android** · by **Mawar Ikhlas Brand**

> Make Every Video Look HD. Optimize your video before sharing.

HD CLEAN prepares a video so TikTok, Instagram Reels, Facebook Stories and
WhatsApp Status receive the cleanest possible upload master. It runs entirely
**on the device**: no upload, no account, no internet needed. The original
video is never modified.

HD CLEAN does **not** promise that platforms won't compress your video. Every
platform re-encodes uploads. HD CLEAN removes the reasons platforms make videos
look *worse than they need to* (HDR, variable frame rate, wrong size,
over-compressed sources, missing fast-start, odd dimensions) and gives the
platform a correctly formatted, high-bitrate master to start from.

## Features

| Area | What it does |
|---|---|
| Smart Analyzer | Resolution, aspect, FPS (and real VFR detection from sample timestamps), bitrate, codec/profile, HDR/SDR, bit depth, audio, size, duration |
| Source quality | Grade from measured bits-per-pixel, with no invented scores |
| **Upload Doctor** | Lists each cause of "video pecah" (broken-up video) found in *this* file and what HD CLEAN does about it |
| Smart encoder | Plans resolution, FPS, bitrate, codec, tone-mapping and audio for each source. Never upscales by default and never stretches |
| No needless re-encode | Already-optimal masters are only re-packaged (fast-start) with zero quality loss |
| Presets | TikTok HD, TikTok 4K (4K sources only, H.264/HEVC), Instagram Reels HD, WhatsApp Status HD, Custom (resolution, FPS, bitrate, codec, audio) |
| Compression | Maximum Quality · Balanced HD · Smaller File, with an estimated output size before processing |
| Framing | Keep original · Fit 9:16 (bars) · Fill 9:16 (crop) |
| Processing | Real engine progress, speed (× real-time), ETA, stages, cancel (deletes the partial file), foreground service on Android |
| Verification | Reads the exported MP4 back: fast-start, profile/level, CFR, BT.709, audio 48 kHz |
| Before/After | Frame-accurate drag slider, pinch-zoom and timeline scrub, plus a spec table. No made-up "% better" figure |
| Save & share | Gallery (Movies/HD CLEAN, Photos), direct TikTok / Instagram / WhatsApp on Android, system share sheet |
| History | Persistent. Recovers after a crash (partial files are cleaned up, entries marked "interrupted") |

### Extra anti-"video pecah" features (beyond the brief)

1. **HDR → SDR tone mapping** (HLG/HDR10/Dolby Vision). This is the #1 cause of
   washed-out or blown-out uploads from iPhones and recent Androids.
2. **VFR → CFR** with real VFR detection. Prevents stutter and audio drift after
   the platform re-encodes.
3. **Exact platform size, downscaled once on-device with a high-quality filter**
   (mipmapped GL minification on Android). This avoids a second, cruder resize
   on the server.
4. **Even-cadence frame-rate reduction** (e.g. 50 → 25, not 50 → 30, for
   WhatsApp), so motion has no judder.
5. **1-second keyframes, progressive, BT.709 tags, even dimensions, fast-start MP4.**
6. **Source-aware bitrate cap**. It never inflates a heavily compressed file and
   warns that lost detail cannot be restored.
7. **AAC passthrough** when the audio is already AAC 48 kHz (no generation loss).
   Otherwise AAC-LC 48 kHz, downmixed to stereo.
8. **WhatsApp Status splitter** (30/60/90 s equal parts).
9. **Optional 1080p upload tier** for 720p sources, clearly labelled as not
   adding detail.
10. **No-transcode picking**:
    - iOS: PHPicker `.current`.
    - Android: media-capabilities declaration, so the OS does not hand the app a
      degraded HEVC→AVC copy.
11. **Per-platform upload checklist**: TikTok "Upload HD", Instagram "Upload at
    highest quality", WhatsApp HD toggle, Wi-Fi, and avoiding in-app filters.

## Architecture

```
lib/
  engine/          Pure Dart, unit-tested
    planner.dart       smart encoding decisions
    upload_doctor.dart diagnosis + platform tips
    mp4_inspector.dart ISO-BMFF reader + fast-start fixer
    presets.dart, models.dart
  services/        native bridge, job runner, history store
  ui/              screens + premium widgets
android/…/hd_clean/
  VideoEngine.kt   Media3 Transformer → MediaCodec HW encode/decode, GL scale/tone-map, InAppMp4Muxer
  VideoProbe.kt    MediaExtractor/MediaMetadataRetriever probe, VFR analysis, frames
  ExportService.kt foreground service for long exports
  MediaActions.kt  MediaStore save, FileProvider share
ios/Runner/AppDelegate.swift
  AVAssetReader + AVVideoComposition (rotation, scale, CFR, BT.709 tone-map)
  AVAssetWriter (VideoToolbox H.264 High / HEVC Main, AAC-LC), PHPicker, Photos save, share sheet
```

The Dart planner decides every parameter, and both native engines execute the
same plan through the `hdclean/engine` method channel and the
`hdclean/progress` event channel. No FFmpeg is shipped, so there are no
GPL/LGPL licensing obligations, and hardware codecs are used.

## Build

Requires Flutter 3.50+, Xcode (iOS 15+), and Android SDK 36 (min Android 7.0).

```bash
flutter pub get
flutter run                      # device
flutter build apk --release      # Android
flutter build ipa                # iOS (needs signing)
```

## Tests

```bash
flutter test                                  # planner, doctor, and the ffmpeg reference pipeline
./tool/make_fixture.sh && flutter test integration_test -d <device>   # REAL native engine on device
SCREENSHOTS=1 flutter test test/screenshots_test.dart                 # design screenshots
```

- **Reference pipeline**
  (`test/reference_pipeline_test.dart`, skipped if ffmpeg is absent)
  1. Generates real sources: 4K HLG HDR 10-bit HEVC at 60 fps, VFR 720p with
     44.1 kHz audio, an optimal master, and a 130 s clip.
  2. Plans each one with the HD CLEAN planner.
  3. Encodes with ffmpeg as a reference encoder.
  4. Fixes the fast-start layout with the Dart fixer.
  5. Decodes the result fully and verifies size, profile, CFR, BT.709,
     48 kHz audio and fast-start.
- **Integration tests** (`integration_test/engine_test.dart`) run the Media3
  and AVFoundation engines themselves: probe, frame grab, export with Fit 9:16,
  segment export, cancel, and a check that the original is untouched.
- **CI** (`.github/workflows/ci.yml`) runs:
  - analysis and unit tests;
  - the Android release build and the integration tests on an emulator;
  - the iOS build and the integration tests on a simulator.

## Platform notes

- **iOS sharing**: Apple offers no public API to send a file straight into
  TikTok, Instagram or WhatsApp without their SDKs. On iOS those buttons open
  the system share sheet, which lists those apps.
- **iOS background**: GPU encoding is suspended in the background. HD CLEAN
  keeps the screen awake during processing and stops cleanly, with a clear
  message, if it is backgrounded for too long.
- **Limited Android encoders**: on devices without the requested settings
  (e.g. 4K60 H.264), Media3 falls back to supported settings. The verification
  card shows what was actually produced.
